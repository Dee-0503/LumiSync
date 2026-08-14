import Foundation
import LumiSyncCore

public enum AppStopReason: Equatable, Sendable {
    case missingInputMonitoring
    case keyboardInputMonitoringUnavailable
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
    public var keyboardInputMonitoringActive: Bool
    public var externalKeyboardActive: Bool
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
            keyboardInputMonitoringActive: false,
            externalKeyboardActive: false,
            keyboardBacklightStatus: .unavailable,
            preferences: preferences.core
        )
    }
}

@MainActor
public final class AppStateCoordinator: ObservableObject {
    @Published public private(set) var snapshot: AppSnapshot {
        didSet {
            onSnapshotChange?(snapshot)
        }
    }
    public var onSnapshotChange: (@MainActor @Sendable (AppSnapshot) -> Void)?

    private let preferencesStore: any AppPreferencesStoring
    private let displayBrightnessReader: any DisplayBrightnessReadingService
    private let keyboardBacklight: any KeyboardBacklightControlling
    private let inputMonitoring: any InputMonitoringControlling
    private let keyboardInputMonitor: (any KeyboardInputMonitoring)?
    private let reconciliationScheduler: any ExternalKeyboardReconciliationScheduling
    private let monotonicSeconds: () -> Int
    private let syncEngine = SyncEngine()
    private var preferences: AppPreferences
    private var externalKeyboardPolicy: ExternalKeyboardPolicy
    private var keyboardInputGeneration: UInt64 = 0

    public init(
        preferencesStore: any AppPreferencesStoring,
        displayBrightnessReader: any DisplayBrightnessReadingService,
        keyboardBacklight: any KeyboardBacklightControlling,
        inputMonitoring: any InputMonitoringControlling,
        keyboardInputMonitor: (any KeyboardInputMonitoring)? = nil,
        reconciliationScheduler: any ExternalKeyboardReconciliationScheduling = DispatchExternalKeyboardReconciliationScheduler(),
        monotonicSeconds: @escaping () -> Int = {
            Int(ProcessInfo.processInfo.systemUptime)
        }
    ) {
        let loadedPreferences = (try? preferencesStore.load()) ?? .defaults
        self.preferencesStore = preferencesStore
        self.displayBrightnessReader = displayBrightnessReader
        self.keyboardBacklight = keyboardBacklight
        self.inputMonitoring = inputMonitoring
        self.keyboardInputMonitor = keyboardInputMonitor
        self.reconciliationScheduler = reconciliationScheduler
        self.monotonicSeconds = monotonicSeconds
        preferences = loadedPreferences
        externalKeyboardPolicy = ExternalKeyboardPolicy(
            excludedDevices: loadedPreferences.core.excludedKeyboardDevices
        )
        snapshot = AppSnapshot.initial(preferences: loadedPreferences)
        updateCapabilityStatus()
    }

    public func start() {
        refresh()
        updateKeyboardInputMonitoring()
    }

    public func stop() {
        stopKeyboardInputMonitoring(resetPolicy: true)
    }

    public func refresh() {
        updateCapabilityStatus()
        guard shouldMonitorKeyboardInput else {
            stopKeyboardInputMonitoring(resetPolicy: true)
            if snapshot.inputMonitoringStatus != .granted {
                snapshot.status = .stopped(.missingInputMonitoring)
            }
            return
        }

        if preferences.isPaused {
            snapshot.status = .paused
            return
        }

        guard snapshot.inputMonitoringStatus == .granted else {
            stopKeyboardInputMonitoring(resetPolicy: true)
            snapshot.status = .stopped(.missingInputMonitoring)
            return
        }

        updateKeyboardInputMonitoring()

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
            stopKeyboardInputMonitoring(resetPolicy: true)
            reconcile()
        case .sessionUnlocked:
            snapshot.sessionLocked = false
            refresh()
        case .displayWillSleep:
            snapshot.displayAsleep = true
            stopKeyboardInputMonitoring(resetPolicy: true)
            reconcile()
        case .displayDidWake:
            snapshot.displayAsleep = false
            refresh()
        case .systemWillSleep:
            snapshot.systemAsleep = true
            stopKeyboardInputMonitoring(resetPolicy: true)
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
        snapshot.externalKeyboardActive = externalKeyboardPolicy.isExternalKeyboardActive
    }

    private var shouldMonitorKeyboardInput: Bool {
        snapshot.inputMonitoringStatus == .granted
            && !snapshot.sessionLocked
            && !snapshot.displayAsleep
            && !snapshot.systemAsleep
    }

    private func updateKeyboardInputMonitoring() {
        guard shouldMonitorKeyboardInput,
              let keyboardInputMonitor,
              !snapshot.keyboardInputMonitoringActive else {
            return
        }

        do {
            keyboardInputGeneration &+= 1
            let generation = keyboardInputGeneration
            try keyboardInputMonitor.start(
                handler: { [weak self] origin in
                    guard let self,
                          self.snapshot.keyboardInputMonitoringActive,
                          self.keyboardInputGeneration == generation else {
                        return
                    }
                    self.recordKeyboardInput(origin)
                },
                runtimeEventHandler: { [weak self] event in
                    guard let self,
                          self.snapshot.keyboardInputMonitoringActive,
                          self.keyboardInputGeneration == generation else {
                        return
                    }
                    self.handleKeyboardInputRuntimeEvent(event)
                }
            )
            snapshot.keyboardInputMonitoringActive = true
        } catch {
            snapshot.keyboardInputMonitoringActive = false
            snapshot.status = snapshot.inputMonitoringStatus == .granted
                ? .stopped(.keyboardInputMonitoringUnavailable)
                : .stopped(.missingInputMonitoring)
        }
    }

    private func stopKeyboardInputMonitoring(resetPolicy: Bool) {
        keyboardInputGeneration &+= 1
        if snapshot.keyboardInputMonitoringActive {
            keyboardInputMonitor?.stop()
        }
        reconciliationScheduler.cancel()
        snapshot.keyboardInputMonitoringActive = false
        if resetPolicy {
            externalKeyboardPolicy = ExternalKeyboardPolicy(
                excludedDevices: preferences.core.excludedKeyboardDevices
            )
            snapshot.externalKeyboardActive = false
        }
    }

    private func handleKeyboardInputRuntimeEvent(_ event: KeyboardInputMonitorRuntimeEvent) {
        keyboardInputGeneration &+= 1
        keyboardInputMonitor?.stop()
        reconciliationScheduler.cancel()
        snapshot.keyboardInputMonitoringActive = false
        externalKeyboardPolicy = ExternalKeyboardPolicy(
            excludedDevices: preferences.core.excludedKeyboardDevices
        )
        snapshot.externalKeyboardActive = false
        updateCapabilityStatus()

        switch event {
        case .permissionRevoked:
            snapshot.status = .stopped(.missingInputMonitoring)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            snapshot.status = snapshot.inputMonitoringStatus == .granted
                ? .stopped(.keyboardInputMonitoringUnavailable)
                : .stopped(.missingInputMonitoring)
        }
    }

    private func recordKeyboardInput(_ origin: KeyboardInputOrigin) {
        let wasExternal = externalKeyboardPolicy.isExternalKeyboardActive
        externalKeyboardPolicy.recordInput(origin, seconds: monotonicSeconds())
        snapshot.externalKeyboardActive = externalKeyboardPolicy.isExternalKeyboardActive

        if externalKeyboardPolicy.isExternalKeyboardActive {
            scheduleExternalKeyboardReconciliation()
        } else {
            reconciliationScheduler.cancel()
        }

        if wasExternal != externalKeyboardPolicy.isExternalKeyboardActive
            || externalKeyboardPolicy.isExternalKeyboardActive {
            reconcile()
        }
    }

    private func scheduleExternalKeyboardReconciliation() {
        reconciliationScheduler.schedule(after: 900) { [weak self] in
            self?.reconcileExternalKeyboardTimeout()
        }
    }

    private func reconcileExternalKeyboardTimeout() {
        externalKeyboardPolicy.tick(seconds: monotonicSeconds())
        snapshot.externalKeyboardActive = externalKeyboardPolicy.isExternalKeyboardActive
        if externalKeyboardPolicy.isExternalKeyboardActive {
            scheduleExternalKeyboardReconciliation()
            return
        }
        reconciliationScheduler.cancel()
        reconcile()
    }

    private func reconcile() {
        if preferences.isPaused {
            snapshot.status = .paused
            return
        }

        guard snapshot.inputMonitoringStatus == .granted else {
            stopKeyboardInputMonitoring(resetPolicy: true)
            snapshot.status = .stopped(.missingInputMonitoring)
            return
        }

        updateKeyboardInputMonitoring()

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
            externalKeyboardActive: externalKeyboardPolicy.isExternalKeyboardActive,
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
