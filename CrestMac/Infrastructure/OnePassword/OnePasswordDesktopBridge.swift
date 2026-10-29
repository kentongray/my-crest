import Foundation

// MARK: - Types

/// Why the 1Password desktop app did not answer.
enum OnePasswordDesktopError: Error, Equatable, Sendable {
    /// No 1Password app with its integration library is installed.
    case appNotInstalled
    /// Crest's bundled helper is missing or would not start.
    case helperUnavailable
    /// The app has "Integrate with other apps" turned off.
    case integrationOff
    /// The app, or the helper reaching it, went away mid-request.
    case connectionDropped
    /// The app's authorization for the helper ran out; a new client is needed.
    case sessionExpired
    /// The app refused the request and said why.
    case refused(String)
    /// The library failed with a code it does not describe.
    case internalFailure(Int32)
    /// The app answered with something this client cannot read.
    case unreadableResponse

    /// One sentence a person can act on.
    var message: String {
        switch self {
        case .appNotInstalled:
            String(localized: "Install the 1Password app to fill from it.")
        case .helperUnavailable:
            String(localized: "Crest couldn’t start its 1Password helper.")
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
        }
    }
}

/// Crest's channel to the 1Password app: the helper in Contents/Helpers that
/// loads the SDK library the app ships and relays one JSON request at a time
/// to it.
///
/// Only the helper carries the entitlement that lets it load another
/// developer's library, so Crest's own process keeps library validation. The
/// helper stays running for as long as Crest needs it, because the app
/// authorizes it per process; one that exits is started again on the next
/// request. A request can wait on the app's authorization prompt for minutes,
/// so every exchange runs on one serial queue of its own and never on Swift's
/// cooperative pool.
final class OnePasswordDesktopBridge: @unchecked Sendable {
    // MARK: - Static Variables

    /// The helper's executable name inside Contents/Helpers.
    static let helperName = "Crest 1Password Helper"
    /// The code the helper answers with when it could not load the library.
    private static let libraryUnavailableCode: Int32 = -1000

    // MARK: - Variables

    // Touched only on `queue`.
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let queue = DispatchQueue(label: "com.pauldavis.crest.onepassword-bridge")

    // MARK: - Actions - Messages

    /// Sends one request to the app and returns its answer.
    func send(_ request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.exchange(request) })
            }
        }
    }

    private func exchange(_ request: Data) throws -> Data {
        let (input, output) = try runningHelper()
        do {
            try input.write(contentsOf: Self.littleEndian(UInt32(request.count)) + request)
        } catch {
            stopHelper()
            throw OnePasswordDesktopError.connectionDropped
        }
        guard let header = Self.read(8, from: output) else {
            stopHelper()
            throw OnePasswordDesktopError.connectionDropped
        }
        let code = Int32(bitPattern: Self.word(header, at: 0))
        let length = Int(Self.word(header, at: 4))
        guard let answer = length == 0 ? Data() : Self.read(length, from: output) else {
            stopHelper()
            throw OnePasswordDesktopError.connectionDropped
        }
        switch code {
        case 0:
            return answer
        case Self.libraryUnavailableCode:
            throw OnePasswordDesktopError.appNotInstalled
        // The codes the official SDKs read on macOS.
        case -3:
            throw OnePasswordDesktopError.integrationOff
        case -7:
            throw OnePasswordDesktopError.connectionDropped
        default:
            throw OnePasswordDesktopError.internalFailure(code)
        }
    }

    // MARK: - Actions - Helper

    private func runningHelper() throws -> (FileHandle, FileHandle) {
        if let process, process.isRunning, let input, let output { return (input, output) }
        stopHelper()
        let executable = Bundle.main.bundleURL.appending(path: "Contents/Helpers/\(Self.helperName)")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw OnePasswordDesktopError.helperUnavailable
        }
        let process = Process()
        let requests = Pipe()
        let answers = Pipe()
        process.executableURL = executable
        process.standardInput = requests
        process.standardOutput = answers
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw OnePasswordDesktopError.helperUnavailable
        }
        self.process = process
        input = requests.fileHandleForWriting
        output = answers.fileHandleForReading
        return (requests.fileHandleForWriting, answers.fileHandleForReading)
    }

    private func stopHelper() {
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        output = nil
    }

    // MARK: - Actions - Framing

    private static func read(_ count: Int, from handle: FileHandle) -> Data? {
        var data = Data()
        while data.count < count {
            guard let chunk = try? handle.read(upToCount: count - data.count), !chunk.isEmpty else { return nil }
            data.append(chunk)
        }
        return data
    }

    private static func word(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
