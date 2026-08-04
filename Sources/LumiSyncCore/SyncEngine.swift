public enum SyncDecision: Equatable, Sendable {
    case stop(reason: StopReason)
    case setKeyboard(Double)
    case preserveCurrent
}

public struct SyncEngine {
    public init() {}

    public func decide(_ snapshot: SyncSnapshot) -> SyncDecision {
        if snapshot.paused {
            return .preserveCurrent
        }
        if !snapshot.inputMonitoringAuthorized {
            return .stop(reason: .missingInputMonitoring)
        }
        if !snapshot.helperAvailable {
            return .stop(reason: .helperUnavailable)
        }
        if snapshot.sessionLocked || snapshot.displayAsleep || snapshot.systemAsleep {
            return .setKeyboard(0.0)
        }
        if snapshot.effectiveDisplayBrightness <= 0.0 {
            return .setKeyboard(0.0)
        }
        if snapshot.externalKeyboardActive {
            return .setKeyboard(0.0)
        }

        return .setKeyboard(
            snapshot.curve.value(
                at: snapshot.effectiveDisplayBrightness,
                intensity: snapshot.intensity
            )
        )
    }
}
