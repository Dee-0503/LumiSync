import Foundation

public struct FakeWriterService: Sendable {
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
                return .success(readback: try device.read(requestID: request.requestID))
            case .set(let value):
                try device.write(value, requestID: request.requestID, operationCategory: .set)
                return .success(readback: try device.read(requestID: request.requestID))
            case .restore(let value):
                try device.write(value, requestID: request.requestID, operationCategory: .restore)
                return .success(readback: try device.read(requestID: request.requestID))
            }
        } catch {
            return .failure(primary: .writerFailed, restoration: .notRequired)
        }
    }
}
