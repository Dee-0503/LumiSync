import ApplicationServices
import AppKit

public enum InputMonitoringStatus: String, Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

public protocol InputMonitoringControlling {
    var status: InputMonitoringStatus { get }
    @discardableResult func requestAccess() -> Bool
    func openSystemSettings()
}

public struct SystemInputMonitoringController: InputMonitoringControlling {
    public init() {}

    public var status: InputMonitoringStatus {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            ? .granted
            : .denied
    }

    @discardableResult
    public func requestAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
