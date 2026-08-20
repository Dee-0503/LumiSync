import Foundation

public protocol BacklightSupervising: Sendable {
    func execute(_ request: BacklightRequest) async -> BacklightOperationResult
}

extension BacklightSafetySupervisor: BacklightSupervising {}

public actor BacklightSafetyController {
    private let supervisor: any BacklightSupervising
    private var activeRequest: BacklightRequest?
    private var activeTask: Task<BacklightOperationResult, Never>?
    private var activeGeneration: UInt64 = 0

    public init(supervisor: any BacklightSupervising) {
        self.supervisor = supervisor
    }

    public func submit(_ request: BacklightRequest) async -> BacklightOperationResult {
        if let activeRequest, let activeTask {
            if activeRequest == request {
                return await activeTask.value
            }
            if Self.isMutation(activeRequest.operation), Self.isMutation(request.operation) {
                return .failure(primary: .rejected, restoration: .notRequired)
            }
            let generation = activeGeneration
            _ = await activeTask.value
            clearActiveRequest(ifGeneration: generation)
            return await submit(request)
        }

        activeGeneration &+= 1
        let generation = activeGeneration
        activeRequest = request
        let task = Task { await supervisor.execute(request) }
        activeTask = task
        let result = await task.value
        clearActiveRequest(ifGeneration: generation)
        return result
    }

    private static func isMutation(_ operation: BacklightOperation) -> Bool {
        switch operation {
        case .set, .restore:
            return true
        case .read:
            return false
        }
    }

    private func clearActiveRequest(ifGeneration generation: UInt64) {
        guard activeGeneration == generation else { return }
        activeRequest = nil
        activeTask = nil
    }
}
