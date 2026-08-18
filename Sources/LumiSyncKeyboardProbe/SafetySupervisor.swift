import Foundation

public struct BacklightSupervisorConfiguration: Sendable {
    public let writerExecutableURL: URL
    public let fakeDeviceDirectory: URL
    public let readbackTolerance: Double
    public let stageDuration: Duration

    public init(
        writerExecutableURL: URL,
        fakeDeviceDirectory: URL,
        readbackTolerance: Double = 0.01,
        stageDuration: Duration = .seconds(1)
    ) {
        self.writerExecutableURL = writerExecutableURL
        self.fakeDeviceDirectory = fakeDeviceDirectory
        self.readbackTolerance = readbackTolerance
        self.stageDuration = stageDuration
    }
}

public actor BacklightSafetySupervisor {
    private let runner: any OwnedProcessRunning
    private let configuration: BacklightSupervisorConfiguration
    private let codec = FramedJSONCodec()

    public init(
        runner: any OwnedProcessRunning,
        configuration: BacklightSupervisorConfiguration
    ) {
        self.runner = runner
        self.configuration = configuration
    }

    public func execute(_ request: BacklightRequest) async -> BacklightOperationResult {
        guard case .read = request.operation else {
            return await executeMutation(request)
        }
        return await executeRead(request)
    }

    private func executeRead(_ request: BacklightRequest) async -> BacklightOperationResult {
        do {
            let result = try await run(request)
            guard case .success(let readback) = result else {
                return .failure(primary: .writerFailed, restoration: .notRequired)
            }
            return .success(readback: readback)
        } catch {
            return .failure(primary: .protocolViolation, restoration: .notRequired)
        }
    }

    private func executeMutation(_ request: BacklightRequest) async -> BacklightOperationResult {
        let original: NormalizedBacklightValue
        do {
            let capture = try await run(
                BacklightRequest(
                    requestID: request.requestID,
                    operation: .read,
                    deadline: try BacklightDeadline(
                        remainingNanoseconds: request.deadline.remainingNanoseconds
                    )
                )
            )
            guard case .success(let readback) = capture else {
                return .failure(primary: .writerFailed, restoration: .notRequired)
            }
            original = readback
        } catch {
            return .failure(primary: .timedOut(stage: .captureOriginal), restoration: .notRequired)
        }

        let mutationResult: BacklightOperationResult
        do {
            mutationResult = try await run(request)
        } catch {
            mutationResult = .failure(
                primary: .protocolViolation,
                restoration: .notRequired
            )
        }

        let restoration = await restore(original, requestID: request.requestID)
        switch restoration {
        case .verified:
            switch mutationResult {
            case .success:
                return mutationResult
            case .failure(let primary, _):
                return .failure(primary: primary, restoration: restoration)
            }
        case .failed:
            return .failure(primary: .restorationFailed, restoration: restoration)
        case .uncertain:
            return .failure(primary: .restorationUncertain, restoration: restoration)
        case .notRequired:
            return .failure(primary: .protocolViolation, restoration: restoration)
        }
    }

    private func restore(
        _ value: NormalizedBacklightValue,
        requestID: BacklightRequestID
    ) async -> RestorationOutcome {
        do {
            let request = BacklightRequest(
                requestID: requestID,
                operation: .restore(value),
                deadline: try BacklightDeadline(
                    remainingNanoseconds: durationNanoseconds(configuration.stageDuration)
                )
            )
            let result = try await run(request)
            guard case .success(let readback) = result else {
                return .failed
            }
            guard abs(readback.rawValue - value.rawValue) <= configuration.readbackTolerance else {
                return .uncertain
            }
            return .verified(readback)
        } catch {
            return .uncertain
        }
    }

    private func run(_ request: BacklightRequest) async throws -> BacklightOperationResult {
        let processRequest = OwnedProcessRequest(
            executableURL: configuration.writerExecutableURL,
            standardInput: try codec.encode(request),
            timeout: configuration.stageDuration
        )
        let result = await runner.run(processRequest)
        guard result.termination == .exited,
              result.exitStatus == 0,
              result.cleanupVerified
        else {
            throw BacklightSupervisorError.processFailed
        }
        return try codec.decode(BacklightOperationResult.self, from: result.stdout)
    }

    private func durationNanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        return UInt64(max(1, components.seconds)) * 1_000_000_000
            + UInt64(max(0, components.attoseconds / 1_000_000_000))
    }
}

private enum BacklightSupervisorError: Error {
    case processFailed
}
