import LumiSyncCore

struct KeyboardInputEventGate {
    private struct Candidate {
        let origin: KeyboardInputOrigin
        let timestampNanoseconds: UInt64
    }

    private let maximumAssociationNanoseconds: UInt64
    private var candidate: Candidate?
    private var ambiguityTimestampNanoseconds: UInt64?

    init(maximumAssociationNanoseconds: UInt64 = 5_000_000) {
        self.maximumAssociationNanoseconds = maximumAssociationNanoseconds
    }

    mutating func recordDeviceTransition(
        origin: KeyboardInputOrigin,
        isPressed: Bool,
        nowNanoseconds: UInt64
    ) {
        guard isPressed else { return }
        expirePendingInput(nowNanoseconds: nowNanoseconds)
        guard ambiguityTimestampNanoseconds == nil else { return }
        guard candidate == nil else {
            candidate = nil
            ambiguityTimestampNanoseconds = nowNanoseconds
            return
        }
        candidate = Candidate(origin: origin, timestampNanoseconds: nowNanoseconds)
    }

    mutating func consumeKeyDown(nowNanoseconds: UInt64) -> KeyboardInputOrigin? {
        expirePendingInput(nowNanoseconds: nowNanoseconds)
        defer { invalidatePendingInput() }
        guard ambiguityTimestampNanoseconds == nil else { return nil }
        return candidate?.origin
    }

    mutating func invalidatePendingInput() {
        candidate = nil
        ambiguityTimestampNanoseconds = nil
    }

    private mutating func expirePendingInput(nowNanoseconds: UInt64) {
        if let candidate,
           isOutsideAssociationWindow(
               since: candidate.timestampNanoseconds,
               nowNanoseconds: nowNanoseconds
           ) {
            self.candidate = nil
        }
        if let ambiguityTimestampNanoseconds,
           isOutsideAssociationWindow(
               since: ambiguityTimestampNanoseconds,
               nowNanoseconds: nowNanoseconds
           ) {
            self.ambiguityTimestampNanoseconds = nil
        }
    }

    private func isOutsideAssociationWindow(
        since timestampNanoseconds: UInt64,
        nowNanoseconds: UInt64
    ) -> Bool {
        nowNanoseconds < timestampNanoseconds
            || nowNanoseconds - timestampNanoseconds > maximumAssociationNanoseconds
    }
}
