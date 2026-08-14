import Foundation
import LumiSyncCore

public enum AppStopReason: Equatable, Sendable {
    case missingInputMonitoring
    case keyboardBacklightUnavailable
    case displayBrightnessUnavailable
    case keyboardBacklightWriteFailed
}

public enum AppRunStatus: Equatable, Sendable {
    case active
    case paused
    case stopped(AppStopReason)
}

public struct AppSnapshot: Equatable, Sendable {
    public var status: AppRunStatus
    public var isPaused: Bool
    public var sessionLocked: Bool
    public var displayAsleep: Bool
    public var systemAsleep: Bool
    public var displayBrightness: Double?
    public var selectedSource: String
    public var fallbackReason: String?
    public var inputMonitoringStatus: InputMonitoringStatus
    public var keyboardBacklightStatus: KeyboardBacklightAvailability
    public var preferences: LumiSyncPreferences

    public static func initial(preferences: AppPreferences) -> AppSnapshot {
        AppSnapshot(
            status: preferences.isPaused ? .paused : .stopped(.keyboardBacklightUnavailable),
            isPaused: preferences.isPaused,
            sessionLocked: false,
            displayAsleep: false,
            systemAsleep: false,
            displayBrightness: nil,
            selectedSource: "Not available",
            fallbackReason: nil,
            inputMonitoringStatus: .notDetermined,
            keyboardBacklightStatus: .unavailable,
            preferences: preferences.core
        )
    }
}

@MainActor
public final class AppStateCoordinator: ObservableObject {
    @Published public private(set) var snapshot: AppSnapshot

    private let preferencesStore: any AppPreferencesStoring
    private let displayBrightnessReader: any DisplayBrightnessReadingService
    private let keyboardBacklight: any KeyboardBacklightControlling
    private let inputMonitoring: any InputMonitoringControlling
    private let syncEngine = SyncEngine()
    private var preferences: AppPreferences

    public init(
        preferencesStore: any AppPreferencesStoring,
        displayBrightnessReader: any DisplayBrightnessReadingService,
        keyboardBacklight: any KeyboardBacklightControlling,
        inputMonitoring: any InputMonitoringControlling
    ) {
        let loadedPreferences = (try? preferencesStore.load()) ?? .defaults
        self.preferencesStore = preferencesStore
        self.displayBrightnessReader = displayBrightnessReader
        self.keyboardBacklight = keyboardBacklight
        self.inputMonitoring = inputMonitoring
        preferences = loadedPreferences
        snapshot = AppSnapshot.initial(preferences: loadedPreferences)
        updateCapabilityStatus()
    }

    public func start() {
        refresh()
    }

    public func refresh() {
        updateCapabilityStatus()

        if preferences.isPaused {
            snapshot.status = .paused
            return
        }

        guard snapshot.inputMonitoringStatus == .granted else {
            snapshot.status = .stopped(.missingInputMonitoring)
            return
        }

        guard snapshot.keyboardBacklightStatus == .available else {
            snapshot.status = .stopped(.keyboardBacklightUnavailable)
            return
        }

        do {
            let reading = try displayBrightnessReader.read()
            snapshot.displayBrightness = reading.value
            snapshot.selectedSource = reading.sourceDescription
            snapshot.fallbackReason = reading.fallbackReason
        } catch {
            snapshot.displayBrightness = nil
            snapshot.selectedSource = "Not available"
            snapshot.fallbackReason = "No readable display brightness is available through public macOS APIs."
            snapshot.status = .stopped(.displayBrightnessUnavailable)
            return
        }

        reconcile()
    }

    public func setPaused(_ isPaused: Bool) {
        preferences.isPaused = isPaused
        snapshot.isPaused = isPaused
        snapshot.status = isPaused ? .paused : snapshot.status
        try? preferencesStore.save(preferences)
        if !isPaused {
            refresh()
        }
    }

    public func togglePaused() {
        setPaused(!preferences.isPaused)
    }

    public func handleWorkspaceEvent(_ event: WorkspaceEvent) {
        switch event {
        case .sessionLocked:
            snapshot.sessionLocked = true
            reconcile()
        case .sessionUnlocked:
            snapshot.sessionLocked = false
            refresh()
        case .displayWillSleep:
            snapshot.displayAsleep = true
            reconcile()
        case .displayDidWake:
            snapshot.displayAsleep = false
            refresh()
        case .systemWillSleep:
            snapshot.systemAsleep = true
            reconcile()
        case .systemDidWake:
            snapshot.systemAsleep = false
            refresh()
        }
    }

    @discardableResult
    public func requestInputMonitoring() -> Bool {
        let granted = inputMonitoring.requestAccess()
        updateCapabilityStatus()
        if granted {
            refresh()
        }
        return granted
    }

    public func openInputMonitoringSettings() {
        inputMonitoring.openSystemSettings()
    }

    private func updateCapabilityStatus() {
        snapshot.inputMonitoringStatus = inputMonitoring.status
        snapshot.keyboardBacklightStatus = keyboardBacklight.availability
        snapshot.preferences = preferences.core
        snapshot.isPaused = preferences.isPaused
    }

    private func reconcile() {
        if preferences.isPaused {
            snapshot.status = .paused
            return
        }

        guard snapshot.inputMonitoringStatus == .granted else {
            snapshot.status = .stopped(.missingInputMonitoring)
            return
        }

        guard snapshot.keyboardBacklightStatus == .available else {
            snapshot.status = .stopped(.keyboardBacklightUnavailable)
            return
        }

        let curve: BrightnessCurve
        switch preferences.core.curveSelection {
        case let .preset(preset):
            curve = preset.curve
        case let .custom(custom):
            curve = custom
        }

        let coreSnapshot = SyncSnapshot(
            inputMonitoringAuthorized: true,
            helperAvailable: true,
            sessionLocked: snapshot.sessionLocked,
            displayAsleep: snapshot.displayAsleep,
            systemAsleep: snapshot.systemAsleep,
            effectiveDisplayBrightness: snapshot.displayBrightness ?? 0,
            externalKeyboardActive: false,
            paused: false,
            curve: curve,
            intensity: preferences.core.intensity
        )

        switch syncEngine.decide(coreSnapshot) {
        case .preserveCurrent:
            snapshot.status = .paused
        case .stop(reason: .missingInputMonitoring):
            snapshot.status = .stopped(.missingInputMonitoring)
        case .stop(reason: .helperUnavailable):
            snapshot.status = .stopped(.keyboardBacklightUnavailable)
        case let .setKeyboard(value):
            do {
                try keyboardBacklight.setBrightness(value)
                snapshot.status = .active
            } catch {
                snapshot.status = .stopped(.keyboardBacklightWriteFailed)
            }
        }
    }
}
