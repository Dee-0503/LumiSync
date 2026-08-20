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
        case .hang(let stage):
            try device.recordHangBarrier(stage: stage, requestID: requestID)
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
        var readyPipe = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&readyPipe) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let childPID = rawFork()
        guard childPID >= 0 else {
            _ = Darwin.close(readyPipe[0])
            _ = Darwin.close(readyPipe[1])
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard childPID == 0 else {
            _ = Darwin.close(readyPipe[1])
            var ready: UInt8 = 0
            let count = Darwin.read(readyPipe[0], &ready, 1)
            _ = Darwin.close(readyPipe[0])
            guard count == 1 else {
                throw POSIXError(.EIO)
            }
            let marker = try NormalizedBacklightValue(0.37)
            try device.recordProcess(
                requestID: requestID,
                value: marker,
                operationCategory: .restore,
                processID: childPID
            )
            _ = Darwin.raise(SIGSTOP)
            return
        }

        _ = Darwin.close(readyPipe[0])
        if createSession {
            _ = setsid()
        }
        var ready: UInt8 = 1
        _ = Darwin.write(readyPipe[1], &ready, 1)
        _ = Darwin.close(readyPipe[1])
        _ = Darwin.close(STDIN_FILENO)
        _ = Darwin.close(STDOUT_FILENO)
        _ = Darwin.close(STDERR_FILENO)
        while true {
            _ = Darwin.pause()
        }
    }
}
