import LumiSyncCore

struct KeyboardInputEventGate {
    private var pendingOrigin: KeyboardInputOrigin?
    private var ambiguous = false

    mutating func recordDeviceTransition(origin: KeyboardInputOrigin, isPressed: Bool) {
        guard isPressed else { return }
        guard !ambiguous else { return }
        guard pendingOrigin == nil else {
            pendingOrigin = nil
            ambiguous = true
            return
        }
        pendingOrigin = origin
    }

    mutating func consumeKeyDown() -> KeyboardInputOrigin? {
        defer { invalidatePendingInput() }
        guard !ambiguous else { return nil }
        return pendingOrigin
    }

    mutating func invalidatePendingInput() {
        pendingOrigin = nil
        ambiguous = false
    }
}
