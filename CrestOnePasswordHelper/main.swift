import Foundation

// Crest's bridge to the 1Password app. Crest starts this program from its
// Contents/Helpers folder and keeps it for as long as it needs 1Password.
//
// The 1Password app ships a library, `libop_sdk_ipc_client.dylib`, that its
// official SDKs use to send one JSON request to the app and receive its JSON
// answer. Loading another developer's library takes the
// `disable-library-validation` entitlement, which this program carries so
// that Crest's own process never has to.
//
// Each request arrives on standard input as a 32-bit little-endian length
// and that many bytes. Each answer leaves on standard output as the library's
// 32-bit little-endian return code, a 32-bit little-endian length and that
// many bytes. The program reads nothing else, writes nothing else, and exits
// when standard input closes, which it does when Crest quits.

typealias SendMessage =
    @convention(c) (
        UnsafePointer<UInt8>, Int, UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>
    ) -> Int32
typealias FreeResponse = @convention(c) (UnsafeMutablePointer<UInt8>?, Int, Int) -> Void

/// A return code no library call produces, sent when the library could not
/// be loaded so Crest can say so.
let libraryUnavailable: Int32 = -1000

let candidatePaths = [
    "/Applications/1Password.app/Contents/Frameworks/libop_sdk_ipc_client.dylib",
    FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Applications/1Password.app/Contents/Frameworks/libop_sdk_ipc_client.dylib").path,
]

func loadLibrary() -> (SendMessage, FreeResponse)? {
    guard let path = candidatePaths.first(where: FileManager.default.fileExists(atPath:)),
        let handle = dlopen(path, RTLD_NOW),
        let send = dlsym(handle, "op_sdk_ipc_send_message"),
        let free = dlsym(handle, "op_sdk_ipc_free_response")
    else { return nil }
    return (unsafeBitCast(send, to: SendMessage.self), unsafeBitCast(free, to: FreeResponse.self))
}

func read(_ count: Int, from input: FileHandle) -> Data? {
    var data = Data()
    while data.count < count {
        guard let chunk = try? input.read(upToCount: count - data.count), !chunk.isEmpty else { return nil }
        data.append(chunk)
    }
    return data
}

func littleEndian(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}

let input = FileHandle.standardInput
let output = FileHandle.standardOutput
let library = loadLibrary()

while let header = read(4, from: input) {
    let length = Int(header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
    // A request past the official SDKs' own limit is not one Crest sends.
    guard length > 0, length <= 64 * 1024 * 1024, let request = read(length, from: input) else { break }

    var code = libraryUnavailable
    var answer = Data()
    if let (sendMessage, freeResponse) = library {
        var response: UnsafeMutablePointer<UInt8>?
        var responseLength = 0
        var responseCapacity = 0
        code = request.withUnsafeBytes { bytes in
            sendMessage(
                bytes.bindMemory(to: UInt8.self).baseAddress!, request.count, &response, &responseLength,
                &responseCapacity)
        }
        if code == 0, let response {
            answer = Data(bytes: response, count: responseLength)
            freeResponse(response, responseLength, responseCapacity)
        }
    }
    output.write(littleEndian(UInt32(bitPattern: code)) + littleEndian(UInt32(answer.count)) + answer)
}
