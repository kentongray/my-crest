import Foundation

// MARK: - Types

/// Why the 1Password desktop app did not answer.
enum OnePasswordDesktopError: Error, Equatable, Sendable {
    /// No 1Password app with its integration library is installed.
    case appNotInstalled
    /// The library is there but this process could not load it.
    case libraryUnavailable
    /// The app has "Integrate with other apps" turned off.
    case integrationOff
    /// The app went away mid-request.
    case connectionDropped
    /// The app's authorization for this process ran out; a new client is needed.
    case sessionExpired
    /// The app refused the request and said why.
    case refused(String)
    /// The library failed with a code it does not describe.
    case internalFailure(Int32)
    /// The app answered with something this client cannot read.
    case unreadableResponse
    /// The 1Password CLI failed and printed why.
    case commandLine(String)
    /// Neither the app's integration library nor the 1Password CLI is usable.
    case noRoute

    /// One sentence a person can act on.
    var message: String {
        switch self {
        case .appNotInstalled:
            String(localized: "Install the 1Password app to fill from it.")
        case .libraryUnavailable:
            String(localized: "Crest couldn’t load 1Password’s integration library.")
        case .integrationOff:
            String(localized: "In 1Password, turn on Settings › Developer › Integrate with other apps.")
        case .connectionDropped:
            String(localized: "1Password stopped responding. Make sure it’s open and unlocked.")
        case .sessionExpired:
            String(localized: "1Password needs you to approve Crest again.")
        case .refused(let reason):
            reason
        case .internalFailure(let code):
            String(localized: "1Password returned an unexpected error (\(code)).")
        case .unreadableResponse:
            String(localized: "Crest couldn’t read 1Password’s answer.")
        case .commandLine(let output):
            Self.commandLineMessage(output)
        case .noRoute:
            String(localized: "Install the 1Password CLI, or allow Crest to load 1Password’s integration library.")
        }
    }

    /// What the CLI's error line says, put as an instruction where it is one
    /// people meet: an approval that timed out or was dismissed, or the app's
    /// CLI integration being off.
    private static func commandLineMessage(_ output: String) -> String {
        let line =
            output.split(whereSeparator: \.isNewline).first.map(String.init)?
            .replacingOccurrences(of: #"^\[ERROR\] \S+ \S+ "#, with: "", options: .regularExpression) ?? ""
        let lowered = line.lowercased()
        if lowered.contains("authorization") || lowered.contains("dismissed") {
            return String(localized: "Approve Crest in 1Password, then check the connection again.")
        }
        if lowered.contains("integration") || lowered.contains("connect to the 1password app") {
            return String(localized: "In 1Password, turn on Settings › Developer › Integrate with 1Password CLI.")
        }
        return line.isEmpty ? String(localized: "The 1Password CLI failed.") : line
    }
}

/// The library the 1Password desktop app ships for its SDKs' desktop
/// integration, which sends one JSON request to the app and returns its JSON
/// answer.
///
/// The app shows its own authorization prompt the first time a process asks,
/// and a call can wait on that prompt for minutes, so every call runs on one
/// serial queue of its own and never on Swift's cooperative pool. The app
/// answers one call per process at a time regardless.
final class OnePasswordDesktopLibrary: @unchecked Sendable {
    // MARK: - Types

    private typealias SendMessage =
        @convention(c) (
            UnsafePointer<UInt8>, Int, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
            UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>
        ) -> Int32
    private typealias FreeResponse = @convention(c) (UnsafeMutablePointer<UInt8>?, Int, Int) -> Void

    // MARK: - Static Variables

    /// Where the 1Password app keeps the library, system-wide first.
    static let candidatePaths = [
        "/Applications/1Password.app/Contents/Frameworks/libop_sdk_ipc_client.dylib",
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications/1Password.app/Contents/Frameworks/libop_sdk_ipc_client.dylib").path,
    ]

    // MARK: - Variables

    // Immutable after `init`; the queue serializes every use of them.
    private let sendMessage: SendMessage
    private let freeResponse: FreeResponse
    private let queue = DispatchQueue(label: "com.pauldavis.crest.onepassword-desktop")

    // MARK: - Initializers

    /// Loads the installed library, or throws why it cannot.
    init() throws {
        guard let path = Self.candidatePaths.first(where: FileManager.default.fileExists(atPath:)) else {
            throw OnePasswordDesktopError.appNotInstalled
        }
        guard let handle = dlopen(path, RTLD_NOW),
            let send = dlsym(handle, "op_sdk_ipc_send_message"),
            let free = dlsym(handle, "op_sdk_ipc_free_response")
        else {
            throw OnePasswordDesktopError.libraryUnavailable
        }
        sendMessage = unsafeBitCast(send, to: SendMessage.self)
        freeResponse = unsafeBitCast(free, to: FreeResponse.self)
    }

    // MARK: - Actions - Messages

    /// Sends one request and returns the app's answer.
    func send(_ request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.sendNow(request) })
            }
        }
    }

    private func sendNow(_ request: Data) throws -> Data {
        var response: UnsafeMutablePointer<UInt8>?
        var length = 0
        var capacity = 0
        let code = request.withUnsafeBytes { bytes -> Int32 in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return sendMessage(base, request.count, &response, &length, &capacity)
        }
        switch code {
        case 0:
            guard let response else { throw OnePasswordDesktopError.unreadableResponse }
            defer { freeResponse(response, length, capacity) }
            return Data(bytes: response, count: length)
        // The codes the official SDKs read on macOS.
        case -3:
            throw OnePasswordDesktopError.integrationOff
        case -7:
            throw OnePasswordDesktopError.connectionDropped
        default:
            throw OnePasswordDesktopError.internalFailure(code)
        }
    }
}
