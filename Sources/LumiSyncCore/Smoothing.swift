public enum BrightnessChangeKind: Equatable, Sendable {
    case manual
    case automatic
}

public struct TransitionPlan: Equatable, Sendable {
    public let debounceMilliseconds: Int
    public let durationMilliseconds: Int
    public let target: Double

    public init(debounceMilliseconds: Int, durationMilliseconds: Int, target: Double) {
        self.debounceMilliseconds = debounceMilliseconds
        self.durationMilliseconds = durationMilliseconds
        self.target = target
    }
}

public struct SmoothingPolicy {
    public init() {}

    public func plan(
        kind: BrightnessChangeKind,
        from current: Double,
        to target: Double
    ) -> TransitionPlan {
        if target == 0 {
            return TransitionPlan(
                debounceMilliseconds: 0,
                durationMilliseconds: 0,
                target: target
            )
        }

        switch kind {
        case .manual:
            return TransitionPlan(
                debounceMilliseconds: 0,
                durationMilliseconds: 300,
                target: target
            )
        case .automatic:
            return TransitionPlan(
                debounceMilliseconds: 500,
                durationMilliseconds: 1_500,
                target: target
            )
        }
    }
}
