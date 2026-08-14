import AppKit

public enum WorkspaceEvent: Equatable, Sendable {
    case sessionLocked
    case sessionUnlocked
    case displayWillSleep
    case displayDidWake
    case systemWillSleep
    case systemDidWake
}

@MainActor
public final class WorkspaceLifecycleMonitor {
    private let workspaceCenter: NotificationCenter
    private let distributedCenter: DistributedNotificationCenter
    private var observers: [NSObjectProtocol] = []

    public var onEvent: ((WorkspaceEvent) -> Void)?

    public init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedCenter: DistributedNotificationCenter = .default()
    ) {
        self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter
    }

    public func start() {
        guard observers.isEmpty else { return }

        observe(workspaceCenter, name: NSWorkspace.willSleepNotification, event: .systemWillSleep)
        observe(workspaceCenter, name: NSWorkspace.didWakeNotification, event: .systemDidWake)
        observe(workspaceCenter, name: NSWorkspace.screensDidSleepNotification, event: .displayWillSleep)
        observe(workspaceCenter, name: NSWorkspace.screensDidWakeNotification, event: .displayDidWake)
        observe(distributedCenter, name: Notification.Name("com.apple.screenIsLocked"), event: .sessionLocked)
        observe(distributedCenter, name: Notification.Name("com.apple.screenIsUnlocked"), event: .sessionUnlocked)
    }

    public func stop() {
        for observer in observers {
            workspaceCenter.removeObserver(observer)
            distributedCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func observe(
        _ center: NotificationCenter,
        name: Notification.Name,
        event: WorkspaceEvent
    ) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.onEvent?(event)
            }
        })
    }
}
