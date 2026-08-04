public enum StopReason: Equatable, Sendable {
    case missingInputMonitoring
    case helperUnavailable
}

public struct SyncSnapshot: Equatable, Sendable {
    public var inputMonitoringAuthorized: Bool
    public var helperAvailable: Bool
    public var sessionLocked: Bool
    public var displayAsleep: Bool
    public var systemAsleep: Bool
    public var effectiveDisplayBrightness: Double
    public var externalKeyboardActive: Bool
    public var paused: Bool
    public var curve: BrightnessCurve
    public var intensity: Double

    public init(
        inputMonitoringAuthorized: Bool,
        helperAvailable: Bool,
        sessionLocked: Bool,
        displayAsleep: Bool,
        systemAsleep: Bool,
        effectiveDisplayBrightness: Double,
        externalKeyboardActive: Bool,
        paused: Bool,
        curve: BrightnessCurve,
        intensity: Double
    ) {
        self.inputMonitoringAuthorized = inputMonitoringAuthorized
        self.helperAvailable = helperAvailable
        self.sessionLocked = sessionLocked
        self.displayAsleep = displayAsleep
        self.systemAsleep = systemAsleep
        self.effectiveDisplayBrightness = effectiveDisplayBrightness
        self.externalKeyboardActive = externalKeyboardActive
        self.paused = paused
        self.curve = curve
        self.intensity = intensity
    }

    public static func normal(displayBrightness: Double) -> SyncSnapshot {
        SyncSnapshot(
            inputMonitoringAuthorized: true,
            helperAvailable: true,
            sessionLocked: false,
            displayAsleep: false,
            systemAsleep: false,
            effectiveDisplayBrightness: displayBrightness,
            externalKeyboardActive: false,
            paused: false,
            curve: CurvePreset.comfort.curve,
            intensity: 1.0
        )
    }
}
