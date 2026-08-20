import Foundation

public protocol BacklightSupervising: Sendable {
    func execute(_ request: BacklightRequest) async -> BacklightOperationResult
}

extension BacklightSafetySupervisor: BacklightSupervising {}

public actor BacklightSafetyController {
    private let supervisor: any BacklightSupervising
    private var activeOperation: BacklightOperation?
    private var activeTask: Task<BacklightOperationResult, Never>?

    public init(supervisor: any BacklightSupervising) {
        self.supervisor = supervisor
    }

    public func submit(_ request: BacklightRequest) async -> BacklightOperationResult {
        switch request.operation {
        case .set, .restore:
            if let activeOperation {
                guard activeOperation == request.operation else {
                    return .failure(primary: .rejected, restoration: .notRequired)
                }
                return await activeTask!.value
            }
            activeOperation = request.operation
            let task = Task { await supervisor.execute(request) }
            activeTask = task
            let result = await task.value
            activeOperation = nil
            activeTask = nil
            return result
        case .read:
            return await supervisor.execute(request)
        }
    }
}
