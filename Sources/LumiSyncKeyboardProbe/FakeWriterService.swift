import Darwin
import Foundation

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
                    device.consumeFault(for: .captureOriginal)
                ) {
                    return result
                }
                return .success(readback: try device.read(requestID: request.requestID))
            case .set(let value):
                if let result = try handleFault(
                    device.consumeFault(for: .write)
                ) {
                    return result
                }
                try device.write(value, requestID: request.requestID)
                if let result = try handleFault(
                    device.consumeFault(for: .writeReadback)
                ) {
                    return result
                }
                return .success(readback: try device.read(requestID: request.requestID))
            case .restore(let value):
                if let result = try handleFault(
                    device.consumeFault(for: .restore)
                ) {
                    return result
                }
                try device.write(
                    value,
                    requestID: request.requestID,
                    operationCategory: .restore
                )
                if let result = try handleFault(
                    device.consumeFault(for: .restoreReadback)
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
        _ fault: FakeBacklightFaultAction?
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
        case .malformedOutput, .forkSleepingChild, .attemptSetsid:
            return .failure(primary: .protocolViolation, restoration: .notRequired)
        }
    }
}
