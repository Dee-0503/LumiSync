import Darwin
import Foundation

@_silgen_name("fork")
private func rawFork() -> pid_t

public struct FakeWriterService {
    public init() {}

    public func execute(
        _ request: BacklightRequest,
        deviceDirectory: URL
    ) -> BacklightOperationResult {
        do {
            let device = try FileBackedFakeBacklightDevice(
                directory: deviceDirectory,
                processRole: .writer
            )

            switch request.operation {
            case .read:
                if let result = try handleFault(
                    device.consumeFault(for: .captureOriginal),
                    device: device,
                    requestID: request.requestID
                ) {
                    return result
                }
                return .success(readback: try device.read(requestID: request.requestID))
            case .set(let value):
                if let result = try handleFault(
                    device.consumeFault(for: .write),
                    device: device,
                    requestID: request.requestID
                ) {
                    return result
                }
                try device.write(value, requestID: request.requestID)
                if let result = try handleFault(
                    device.consumeFault(for: .writeReadback),
                    device: device,
                    requestID: request.requestID
                ) {
                    return result
                }
                return .success(readback: try device.read(requestID: request.requestID))
            case .restore(let value):
                if let result = try handleFault(
                    device.consumeFault(for: .restore),
                    device: device,
                    requestID: request.requestID
                ) {
                    return result
                }
                try device.write(
                    value,
                    requestID: request.requestID,
                    operationCategory: .restore
                )
                if let result = try handleFault(
                    device.consumeFault(for: .restoreReadback),
                    device: device,
                    requestID: request.requestID
                ) {
                    return result
                }
                return .success(readback: try device.read(requestID: request.requestID))
            }
        } catch FakeBacklightDeviceError.invalidDirectory,
                FakeBacklightDeviceError.invalidFile {
            return .failure(primary: .rejected, restoration: .notRequired)
        } catch {
            return .failure(primary: .writerFailed, restoration: .notRequired)
        }
    }

    private func handleFault(
        _ fault: FakeBacklightFaultAction?,
        device: FileBackedFakeBacklightDevice,
        requestID: BacklightRequestID
    ) throws -> BacklightOperationResult? {
        guard let fault else { return nil }
        switch fault {
        case .returnValue(let value):
            return .success(readback: value)
        case .sleepNanoseconds(let nanoseconds):
            Thread.sleep(forTimeInterval: Double(nanoseconds) / 1_000_000_000)
            return nil
        case .exit(let code):
            Darwin.exit(code)
        case .raise(let signal):
            _ = Darwin.raise(signal)
            return .failure(primary: .writerFailed, restoration: .notRequired)
        case .hang:
            while true {
                _ = Darwin.pause()
            }
        case .malformedOutput:
            try FileHandle.standardOutput.write(contentsOf: Data([0]))
            return .failure(primary: .protocolViolation, restoration: .notRequired)
        case .forkSleepingChild:
            try spawnEscapingChild(device: device, requestID: requestID, createSession: false)
            return .failure(primary: .protocolViolation, restoration: .notRequired)
        case .attemptSetsid:
            try spawnEscapingChild(device: device, requestID: requestID, createSession: true)
            return .failure(primary: .protocolViolation, restoration: .notRequired)
        }
    }

    private func spawnEscapingChild(
        device: FileBackedFakeBacklightDevice,
        requestID: BacklightRequestID,
        createSession: Bool
    ) throws {
        let childPID = rawFork()
        guard childPID >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard childPID == 0 else {
            _ = Darwin.raise(SIGSTOP)
            return
        }
        if createSession {
            _ = setsid()
        }
        _ = Darwin.close(STDIN_FILENO)
        _ = Darwin.close(STDOUT_FILENO)
        _ = Darwin.close(STDERR_FILENO)
        let marker = try! NormalizedBacklightValue(0.37)
        try? device.write(
            marker,
            requestID: requestID,
            operationCategory: .restore
        )
        while true {
            _ = Darwin.pause()
        }
    }
}
