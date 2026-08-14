import AppKit
import LumiSyncAppSupport
import LumiSyncCore
import SwiftUI

@main
struct LumiSyncApp: App {
    @StateObject private var model: AppModel

    init() {
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        MenuBarExtra("LumiSync", systemImage: model.menuBarSystemImage) {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.statusDescription, systemImage: model.menuBarSystemImage)
                    .font(.headline)
                Text(model.sourceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Button(model.snapshot.isPaused ? "Resume" : "Pause") {
                    model.togglePaused()
                }
                Button("Refresh") {
                    model.refresh()
                }
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
                Divider()
                Button("Quit LumiSync") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding()
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: AppSnapshot

    let coordinator: AppStateCoordinator
    private let lifecycleMonitor: WorkspaceLifecycleMonitor

    init(
        coordinator: AppStateCoordinator = AppStateCoordinator(
            preferencesStore: UserDefaultsAppPreferencesStore(),
            displayBrightnessReader: PublicDisplayBrightnessReader(),
            keyboardBacklight: UnavailableKeyboardBacklightController(),
            inputMonitoring: SystemInputMonitoringController()
        ),
        lifecycleMonitor: WorkspaceLifecycleMonitor = WorkspaceLifecycleMonitor()
    ) {
        self.coordinator = coordinator
        self.lifecycleMonitor = lifecycleMonitor
        snapshot = coordinator.snapshot

        lifecycleMonitor.onEvent = { [weak self] event in
            self?.coordinator.handleWorkspaceEvent(event)
            self?.snapshot = coordinator.snapshot
        }
        lifecycleMonitor.start()
        coordinator.start()
        snapshot = coordinator.snapshot
    }

    var menuBarSystemImage: String {
        switch snapshot.status {
        case .active:
            "keyboard.badge.ellipsis"
        case .paused:
            "pause.circle"
        case .stopped:
            "exclamationmark.triangle"
        }
    }

    var statusDescription: String {
        switch snapshot.status {
        case .active:
            "Active"
        case .paused:
            "Paused"
        case let .stopped(reason):
            switch reason {
            case .missingInputMonitoring:
                "Input Monitoring required"
            case .keyboardBacklightUnavailable:
                "Keyboard backlight unavailable"
            case .displayBrightnessUnavailable:
                "Display brightness unavailable"
            case .keyboardBacklightWriteFailed:
                "Keyboard backlight write failed"
            }
        }
    }

    var sourceDescription: String {
        if let brightness = snapshot.displayBrightness {
            return "\(snapshot.selectedSource): \(brightness.formatted(.percent.precision(.fractionLength(0))))"
        }
        return snapshot.selectedSource
    }

    func togglePaused() {
        coordinator.togglePaused()
        snapshot = coordinator.snapshot
    }

    func refresh() {
        coordinator.refresh()
        snapshot = coordinator.snapshot
    }

    func requestInputMonitoring() {
        _ = coordinator.requestInputMonitoring()
        snapshot = coordinator.snapshot
    }

    func openInputMonitoringSettings() {
        coordinator.openInputMonitoringSettings()
    }
}
