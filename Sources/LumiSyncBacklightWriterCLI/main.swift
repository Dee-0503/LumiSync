import Darwin
import Foundation
import LumiSyncKeyboardProbe

let codec = FramedJSONCodec()

func emit(_ result: BacklightOperationResult) -> Never {
    do {
        try FileHandle.standardOutput.write(contentsOf: codec.encode(result))
        exit(EX_OK)
    } catch {
        FileHandle.standardError.write(Data("invalid result frame\n".utf8))
        exit(EX_PROTOCOL)
    }
}

let input = FileHandle.standardInput.readDataToEndOfFile()
let request: BacklightRequest
do {
    request = try codec.decode(BacklightRequest.self, from: input)
} catch {
    emit(.failure(primary: .protocolViolation, restoration: .notRequired))
}

guard let directoryPath = ProcessInfo.processInfo.environment["LUMISYNC_H1_FAKE_DEVICE_DIR"],
      !directoryPath.isEmpty else {
    emit(.failure(primary: .rejected, restoration: .notRequired))
}

emit(
    FakeWriterService().execute(
        request,
        deviceDirectory: URL(fileURLWithPath: directoryPath, isDirectory: true)
    )
)
