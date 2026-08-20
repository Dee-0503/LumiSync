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

let request: BacklightRequest
do {
    request = try FramedJSONReader().read(
        BacklightRequest.self,
        from: .standardInput
    )
} catch {
    emit(.failure(primary: .protocolViolation, restoration: .notRequired))
}

let environment = ProcessInfo.processInfo.environment
guard let executableURL = Bundle.main.executableURL,
      let writerURL = try? TrustedH1Helper.resolve(.writer, relativeTo: executableURL),
      let directoryPath = environment["LUMISYNC_H1_FAKE_DEVICE_DIR"],
      !directoryPath.isEmpty else {
    emit(.failure(primary: .rejected, restoration: .notRequired))
}

let supervisor = BacklightSafetySupervisor(
    runner: BoundedOwnedProcessRunner(),
    configuration: BacklightSupervisorConfiguration(
        writerExecutableURL: writerURL,
        fakeDeviceDirectory: URL(fileURLWithPath: directoryPath, isDirectory: true)
    )
)
emit(await supervisor.execute(request))
