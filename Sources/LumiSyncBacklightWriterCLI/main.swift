import Darwin
import Foundation
import LumiSyncKeyboardProbe

let codec = FramedJSONCodec()
let input = FileHandle.standardInput.readDataToEndOfFile()
let request: BacklightRequest
 do {
    request = try codec.decode(BacklightRequest.self, from: input)
} catch {
    FileHandle.standardError.write(Data("invalid request frame\n".utf8))
    exit(EX_PROTOCOL)
}

guard let directoryPath = ProcessInfo.processInfo.environment["LUMISYNC_H1_FAKE_DEVICE_DIR"] else {
    FileHandle.standardError.write(Data("missing fake device directory\n".utf8))
    exit(EX_UNAVAILABLE)
}

let result = FakeWriterService().execute(
    request,
    deviceDirectory: URL(fileURLWithPath: directoryPath, isDirectory: true)
)

do {
    try FileHandle.standardOutput.write(contentsOf: codec.encode(result))
} catch {
    FileHandle.standardError.write(Data("invalid result frame\n".utf8))
    exit(EX_PROTOCOL)
}
