import Foundation

enum KeyboardInputNativeCallbackTrampoline {
    @discardableResult
    static func withContext(
        token: UnsafeMutableRawPointer?,
        _ operation: (KeyboardInputNativeCallbackContext) -> Void
    ) -> Bool {
        guard let lease = KeyboardInputNativeCallbackRegistry.shared.acquire(token) else {
            return false
        }
        defer { lease.release() }
        operation(lease.context)
        return true
    }
}

final class KeyboardInputNativeCallbackLeaseReleaseState: @unchecked Sendable {
    private let lock = NSLock()
    private let beforeStateTransition: (@Sendable () -> Void)?
    private var released = false

    init(beforeStateTransition: (@Sendable () -> Void)? = nil) {
        self.beforeStateTransition = beforeStateTransition
    }

    func transitionToReleased() -> Bool {
        lock.withLock {
            guard !released else { return false }
            beforeStateTransition?()
            released = true
            return true
        }
    }
}

/// Process-wide callback token registry. Native callbacks receive only the opaque token;
/// they never dereference a Swift object through that raw pointer.
final class KeyboardInputNativeCallbackRegistry: @unchecked Sendable {
    static let shared = KeyboardInputNativeCallbackRegistry()

    final class Lease: @unchecked Sendable {
        let context: KeyboardInputNativeCallbackContext
        private let registry: KeyboardInputNativeCallbackRegistry
        private let token: UInt
        private let releaseState: KeyboardInputNativeCallbackLeaseReleaseState
        private let didReleaseLease: (@Sendable () -> Void)?

        fileprivate init(
            context: KeyboardInputNativeCallbackContext,
            registry: KeyboardInputNativeCallbackRegistry,
            token: UInt,
            releaseState: KeyboardInputNativeCallbackLeaseReleaseState,
            didReleaseLease: (@Sendable () -> Void)?
        ) {
            self.context = context
            self.registry = registry
            self.token = token
            self.releaseState = releaseState
            self.didReleaseLease = didReleaseLease
        }

        func release() {
            guard releaseState.transitionToReleased() else { return }
            registry.releaseLease(token: token)
            didReleaseLease?()
        }

        deinit {
            release()
        }
    }

    private struct Entry {
        let context: KeyboardInputNativeCallbackContext
        var inFlight = 0
        var retired = false
    }

    private let condition = NSCondition()
    private var entries: [UInt: Entry] = [:]
    private var nextToken: UInt = 1

    private init() {}

    func register(_ context: KeyboardInputNativeCallbackContext) -> UnsafeMutableRawPointer {
        condition.lock()
        defer { condition.unlock() }
        let token = nextToken
        nextToken &+= 1
        precondition(token != 0)
        entries[token] = Entry(context: context)
        return UnsafeMutableRawPointer(bitPattern: token)!
    }

    func acquire(
        _ rawToken: UnsafeMutableRawPointer?,
        afterIncrement: (@Sendable () -> Void)? = nil,
        whileLocked: (@Sendable () -> Void)? = nil,
        beforeReleaseStateTransition: (@Sendable () -> Void)? = nil,
        didReleaseLease: (@Sendable () -> Void)? = nil
    ) -> Lease? {
        guard let rawToken else { return nil }
        let token = UInt(bitPattern: rawToken)
        condition.lock()
        guard var entry = entries[token], !entry.retired else {
            condition.unlock()
            return nil
        }
        entry.inFlight += 1
        entries[token] = entry
        let context = entry.context
        whileLocked?()
        condition.unlock()

        afterIncrement?()
        return Lease(
            context: context,
            registry: self,
            token: token,
            releaseState: KeyboardInputNativeCallbackLeaseReleaseState(
                beforeStateTransition: beforeReleaseStateTransition
            ),
            didReleaseLease: didReleaseLease
        )
    }

    func retire(
        _ rawToken: UnsafeMutableRawPointer,
        beforeWait: (@Sendable () -> Void)? = nil
    ) {
        let token = UInt(bitPattern: rawToken)
        condition.lock()
        guard var entry = entries[token] else {
            condition.unlock()
            return
        }
        entry.retired = true
        entries[token] = entry
        if entry.inFlight > 0 {
            beforeWait?()
        }
        while entries[token]?.inFlight ?? 0 > 0 {
            condition.wait()
        }
        entries.removeValue(forKey: token)
        condition.unlock()
    }

    private func releaseLease(token: UInt) {
        condition.lock()
        if var entry = entries[token] {
            entry.inFlight -= 1
            precondition(entry.inFlight >= 0)
            entries[token] = entry
            if entry.retired && entry.inFlight == 0 {
                condition.broadcast()
            }
        }
        condition.unlock()
    }
}
