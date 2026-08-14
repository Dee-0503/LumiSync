import Foundation
import LumiSyncCore

public enum KeyboardInputMonitoringError: Error, Equatable {
    case inputMonitoringNotAuthorized
    case eventTapUnavailable
}

public enum KeyboardInputMonitorRuntimeEvent: Equatable, Sendable {
    case tapDisabledByTimeout
    case tapDisabledByUserInput
    case permissionRevoked
}

/// Reports only the originating keyboard class and non-sensitive device identity.
/// Implementations must not expose or retain keycodes, characters, or input sequences.
public protocol KeyboardInputMonitoring: AnyObject {
    func start(
        handler: @escaping @MainActor @Sendable (KeyboardInputOrigin) -> Void,
        runtimeEventHandler: @escaping @MainActor @Sendable (KeyboardInputMonitorRuntimeEvent) -> Void
    ) throws
    func stop()
}

public protocol ExternalKeyboardReconciliationScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    )
    func cancel()
}

public final class DispatchExternalKeyboardReconciliationScheduler: ExternalKeyboardReconciliationScheduling {
    private var workItem: DispatchWorkItem?

    public init() {}

    public func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        cancel()
        let workItem = DispatchWorkItem {
            Task { @MainActor in
                action()
            }
        }
        self.workItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    public func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
