import Foundation

public struct BacklightSupervisorConfiguration: Sendable {
    public let writerExecutableURL: URL
    public let fakeDeviceDirectory: URL
    public let readbackTolerance: Double

    public init(
        writerExecutableURL: URL,
        fakeDeviceDirectory: URL,
        readbackTolerance: Double = 0.01
    ) {
        self.writerExecutableURL = writerExecutableURL
        self.fakeDeviceDirectory = fakeDeviceDirectory
        self.readbackTolerance = readbackTolerance
    }
}

public actor BacklightSafetySupervisor {
    private struct StageExecution {
        let result: BacklightOperationResult
        let timedOut: Bool
    }

    private static let maximumChildNanoseconds: UInt64 = 500_000_000

    private let runner: OwnedProcessRunning
    private let configuration: BacklightSupervisorConfiguration

    public init(runner: OwnedProcessRunning, configuration: BacklightSupervisorConfiguration) {
        self.runner = runner
        self.configuration = configuration
    }

    public func execute(_ request: BacklightRequest) async -> BacklightOperationResult {
        let operationDeadline = ContinuousClock.now.advanced(
            by: .nanoseconds(Int64(request.deadline.remainingNanoseconds))
        )
        switch request.operation {
        case .read:
            return await perform(
                request,
                stage: .captureOriginal,
                operationDeadline: operationDeadline
            ).result
        case .set:
            let originalRequest = childRequest(
                from: request,
                operation: .read,
                remainingNanoseconds: remainingNanoseconds(until: operationDeadline)
            )
            guard let originalRequest else {
                return .failure(
                    primary: .timedOut(stage: .captureOriginal),
                    restoration: .notRequired
                )
            }
            let originalExecution = await perform(
                originalRequest,
                stage: .captureOriginal,
                operationDeadline: operationDeadline
            )
            guard case .success(let original) = originalExecution.result else {
                return originalExecution.result
            }

            let mutationRequest = childRequest(
                from: request,
                operation: request.operation,
                remainingNanoseconds: remainingNanoseconds(until: operationDeadline)
            )
            let mutationExecution: StageExecution
            if let mutationRequest {
                mutationExecution = await perform(
                    mutationRequest,
                    stage: .write,
                    operationDeadline: operationDeadline
                )
            } else {
                mutationExecution = StageExecution(
                    result: .failure(
                        primary: .timedOut(stage: .write),
                        restoration: .notRequired
                    ),
                    timedOut: true
                )
            }
            let mutationResult = resolvedMutationResult(
                mutationExecution,
                requestID: request.requestID
            )

            let restoreRequest = childRequest(
                from: request,
                operation: .restore(original),
                remainingNanoseconds: remainingNanoseconds(until: operationDeadline)
            )
            let restoreExecution: StageExecution
            if let restoreRequest {
                restoreExecution = await perform(
                    restoreRequest,
                    stage: .restore,
                    operationDeadline: operationDeadline
                )
            } else {
                restoreExecution = StageExecution(
                    result: .failure(
                        primary: .timedOut(stage: .restore),
                        restoration: .notRequired
                    ),
                    timedOut: true
                )
            }
            let restoration = restorationOutcome(
                from: restoreExecution,
                original: original,
                requestID: request.requestID
            )

            switch mutationResult {
            case .success(let readback):
                return restoration == .verified(original)
                    ? .success(readback: readback)
                    : .resolvedFailure(primary: nil, restoration: restoration)
            case .failure(let primary, _):
                return .resolvedFailure(primary: primary, restoration: restoration)
            }
        case .restore:
            return await perform(
                request,
                stage: .restore,
                operationDeadline: operationDeadline
            ).result
        }
    }

    private func perform(
        _ request: BacklightRequest,
        stage: BacklightStage,
        operationDeadline: ContinuousClock.Instant
    ) async -> StageExecution {
        let remaining = remainingNanoseconds(until: operationDeadline)
        guard remaining > 0 else {
            return StageExecution(
                result: .failure(primary: .timedOut(stage: stage), restoration: .notRequired),
                timedOut: true
            )
        }
        let childNanoseconds = min(remaining, Self.maximumChildNanoseconds)
        guard let childRequest = childRequest(
            from: request,
            operation: request.operation,
            remainingNanoseconds: childNanoseconds
        ) else {
            return StageExecution(
                result: .failure(primary: .timedOut(stage: stage), restoration: .notRequired),
                timedOut: true
            )
        }
        let encoded = (try? FramedJSONCodec().encode(childRequest)) ?? Data()
        let process = await runner.run(
            OwnedProcessRequest(
                executableURL: configuration.writerExecutableURL,
                arguments: [childRequest.operationName, childRequest.operationValue],
                standardInput: encoded,
                timeout: .nanoseconds(Int64(childNanoseconds)),
                environment: [
                    "LUMISYNC_H1_FAKE_DEVICE_DIR": configuration.fakeDeviceDirectory.path
                ]
            )
        )
        if process.termination == .timedOut {
            return StageExecution(
                result: .failure(primary: .timedOut(stage: stage), restoration: .notRequired),
                timedOut: true
            )
        }
        guard process.termination == .exited,
              process.exitStatus == 0,
              process.cleanupVerified else {
            return StageExecution(
                result: .failure(primary: .writerFailed, restoration: .notRequired),
                timedOut: false
            )
        }
        let result = (try? FramedJSONCodec().decode(
            BacklightOperationResult.self,
            from: process.stdout
        )) ?? .failure(primary: .protocolViolation, restoration: .notRequired)
        return StageExecution(result: result, timedOut: false)
    }

    private func resolvedMutationResult(
        _ execution: StageExecution,
        requestID: BacklightRequestID
    ) -> BacklightOperationResult {
        guard execution.timedOut else { return execution.result }
        let stage: BacklightStage = journalContains(
            requestID: requestID,
            category: .set
        ) ? .writeReadback : .write
        return .failure(primary: .timedOut(stage: stage), restoration: .notRequired)
    }

    private func restorationOutcome(
        from execution: StageExecution,
        original: NormalizedBacklightValue,
        requestID: BacklightRequestID
    ) -> RestorationOutcome {
        if execution.timedOut {
            return journalContains(requestID: requestID, category: .restore)
                ? .uncertain
                : .failed
        }
        if case .success(let restored) = execution.result,
           abs(restored.rawValue - original.rawValue) <= configuration.readbackTolerance {
            return .verified(restored)
        }
        return .failed
    }

    private func journalContains(
        requestID: BacklightRequestID,
        category: FakeBacklightOperationCategory
    ) -> Bool {
        guard let device = try? FileBackedFakeBacklightDevice(
            directory: configuration.fakeDeviceDirectory,
            processRole: .supervisor
        ),
        let entries = try? device.journalEntries() else {
            return false
        }
        return entries.contains {
            $0.requestID == requestID && $0.operationCategory == category
        }
    }

    private func childRequest(
        from request: BacklightRequest,
        operation: BacklightOperation,
        remainingNanoseconds: UInt64
    ) -> BacklightRequest? {
        guard let deadline = try? BacklightDeadline(
            remainingNanoseconds: remainingNanoseconds
        ) else {
            return nil
        }
        return BacklightRequest(
            requestID: request.requestID,
            operation: operation,
            deadline: deadline
        )
    }

    private func remainingNanoseconds(
        until deadline: ContinuousClock.Instant
    ) -> UInt64 {
        let remaining = ContinuousClock.now.duration(to: deadline)
        let components = remaining.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return 0
        }
        let seconds = UInt64(components.seconds)
        let nanoseconds = UInt64(components.attoseconds) / 1_000_000_000
        return seconds.multipliedReportingOverflow(by: 1_000_000_000).partialValue
            .addingReportingOverflow(nanoseconds).partialValue
    }
}

private extension BacklightRequest {
    var operationName: String {
        switch operation { case .read: return "read"; case .set: return "set"; case .restore: return "restore" }
    }
    var operationValue: String {
        switch operation { case .read: return "0"; case .set(let value), .restore(let value): return String(value.rawValue) }
    }
}
