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
guard let supervisorPath = environment["LUMISYNC_H1_SUPERVISOR_PATH"],
      let writerPath = environment["LUMISYNC_H1_WRITER_PATH"],
      let directoryPath = environment["LUMISYNC_H1_FAKE_DEVICE_DIR"],
      !supervisorPath.isEmpty,
      !writerPath.isEmpty,
      !directoryPath.isEmpty else {
    emit(.failure(primary: .rejected, restoration: .notRequired))
}

let supervisorTimeoutNanoseconds = request.deadline.remainingNanoseconds.addingReportingOverflow(
    BacklightSafetySupervisor.recoveryBudgetNanoseconds
)
guard !supervisorTimeoutNanoseconds.overflow,
      supervisorTimeoutNanoseconds.partialValue <= UInt64(Int64.max) else {
    emit(.failure(primary: .rejected, restoration: .notRequired))
}

let process = await BoundedOwnedProcessRunner().run(
    OwnedProcessRequest(
        executableURL: URL(fileURLWithPath: supervisorPath),
        standardInput: try codec.encode(request),
        timeout: .nanoseconds(Int64(supervisorTimeoutNanoseconds.partialValue)),
        environment: [
            "LUMISYNC_H1_WRITER_PATH": writerPath,
            "LUMISYNC_H1_FAKE_DEVICE_DIR": directoryPath
        ],
        descendantPolicy: .executableContractNoDescendants
    )
)

guard process.termination == .exited,
      process.exitStatus == EX_OK,
      process.cleanupVerified else {
    emit(.failure(primary: .writerFailed, restoration: .notRequired))
}

guard let result = try? codec.decode(BacklightOperationResult.self, from: process.stdout) else {
    emit(.failure(primary: .protocolViolation, restoration: .notRequired))
}
emit(result)
