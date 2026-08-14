import LumiSyncCore

struct KeyboardInputEventGate {
    private struct Candidate {
        let origin: KeyboardInputOrigin
        let timestampNanoseconds: UInt64
    }

    private let maximumAssociationNanoseconds: UInt64
    private var candidate: Candidate?
    private var ambiguous = false

    init(maximumAssociationNanoseconds: UInt64 = 5_000_000) {
        self.maximumAssociationNanoseconds = maximumAssociationNanoseconds
    }

    mutating func recordDeviceTransition(
        origin: KeyboardInputOrigin,
        isPressed: Bool,
        nowNanoseconds: UInt64
    ) {
        guard isPressed else { return }
        expireCandidate(nowNanoseconds: nowNanoseconds)
        guard !ambiguous else { return }
        guard candidate == nil else {
            candidate = nil
            ambiguous = true
            return
        }
        candidate = Candidate(origin: origin, timestampNanoseconds: nowNanoseconds)
    }

    mutating func consumeKeyDown(nowNanoseconds: UInt64) -> KeyboardInputOrigin? {
        expireCandidate(nowNanoseconds: nowNanoseconds)
        defer { invalidatePendingInput() }
        guard !ambiguous else { return nil }
        return candidate?.origin
    }

    mutating func invalidatePendingInput() {
        candidate = nil
        ambiguous = false
    }

    private mutating func expireCandidate(nowNanoseconds: UInt64) {
        guard let candidate else { return }
        guard nowNanoseconds >= candidate.timestampNanoseconds,
              nowNanoseconds - candidate.timestampNanoseconds <= maximumAssociationNanoseconds else {
            invalidatePendingInput()
            return
        }
    }
}
