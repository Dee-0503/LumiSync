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

let environment = ProcessInfo.processInfo.environment
guard let writerPath = environment["LUMISYNC_H1_WRITER_PATH"],
      let directoryPath = environment["LUMISYNC_H1_FAKE_DEVICE_DIR"],
      !writerPath.isEmpty,
      !directoryPath.isEmpty else {
    emit(.failure(primary: .rejected, restoration: .notRequired))
}

let supervisor = BacklightSafetySupervisor(
    runner: BoundedOwnedProcessRunner(),
    configuration: BacklightSupervisorConfiguration(
        writerExecutableURL: URL(fileURLWithPath: writerPath),
        fakeDeviceDirectory: URL(fileURLWithPath: directoryPath, isDirectory: true)
    )
)
emit(await supervisor.execute(request))
