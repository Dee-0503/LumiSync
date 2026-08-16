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
                Button(model.localizer.string(model.snapshot.isPaused ? "menu.resume" : "menu.pause")) {
                    model.togglePaused()
                }
                Button(model.localizer.string("menu.refresh")) {
                    model.refresh()
                }
                SettingsLink {
                    Label(model.localizer.string("menu.settings"), systemImage: "gearshape")
                }
                Divider()
                Button(model.localizer.string("menu.quit")) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding()
            .environment(\.locale, model.localizer.locale)
        }

        Settings {
            SettingsView(model: model)
                .environment(\.locale, model.localizer.locale)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: AppSnapshot

    let coordinator: AppStateCoordinator
    private let lifecycleMonitor: WorkspaceLifecycleMonitor
    private let keyboardInputMonitor: SystemKeyboardInputMonitor?

    init(
        coordinator: AppStateCoordinator? = nil,
        lifecycleMonitor: WorkspaceLifecycleMonitor = WorkspaceLifecycleMonitor()
    ) {
        let keyboardInputMonitor = coordinator == nil ? SystemKeyboardInputMonitor() : nil
        let resolvedCoordinator = coordinator ?? AppStateCoordinator(
            preferencesStore: UserDefaultsAppPreferencesStore(),
            displayBrightnessReader: PublicDisplayBrightnessReader(),
            keyboardBacklight: UnavailableKeyboardBacklightController(),
            inputMonitoring: SystemInputMonitoringController(),
            keyboardInputMonitor: keyboardInputMonitor
        )
        self.coordinator = resolvedCoordinator
        self.lifecycleMonitor = lifecycleMonitor
        self.keyboardInputMonitor = keyboardInputMonitor
        snapshot = resolvedCoordinator.snapshot
        resolvedCoordinator.onSnapshotChange = { [weak self] snapshot in
            self?.snapshot = snapshot
        }

        lifecycleMonitor.onEvent = { [weak self] event in
            self?.coordinator.handleWorkspaceEvent(event)
            self?.snapshot = resolvedCoordinator.snapshot
        }
        lifecycleMonitor.start()
        resolvedCoordinator.start()
        snapshot = resolvedCoordinator.snapshot
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

    var localizer: AppLocalizer {
        AppLocalizer(language: snapshot.language)
    }

    var statusDescription: String {
        switch snapshot.status {
        case .active:
            localizer.string("status.active")
        case .paused:
            localizer.string("status.paused")
        case let .stopped(reason):
            switch reason {
            case .missingInputMonitoring:
                localizer.string("status.inputMonitoringRequired")
            case .keyboardInputMonitoringUnavailable:
                localizer.string("status.keyboardInputUnavailable")
            case .keyboardBacklightUnavailable:
                localizer.string("status.keyboardBacklightUnavailable")
            case .displayBrightnessUnavailable:
                localizer.string("status.displayBrightnessUnavailable")
            case .keyboardBacklightWriteFailed:
                localizer.string("status.keyboardWriteFailed")
            }
        }
    }

    var sourceDescription: String {
        let source = localizer.displaySource(snapshot.selectedSource)
        if let brightness = snapshot.displayBrightness {
            return "\(source): \(brightness.formatted(.percent.precision(.fractionLength(0))))"
        }
        return source
    }

    func localizedFallbackReason(_ reason: String) -> String {
        localizer.fallbackReason(reason)
    }

    func setLanguage(_ language: AppLanguage) {
        coordinator.setLanguage(language)
        snapshot = coordinator.snapshot
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
