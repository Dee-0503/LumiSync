import LumiSyncCore

struct KeyboardInputDeliveryGate {
    private(set) var generation: UInt64 = 0
    private(set) var isRunning = false

    mutating func start() -> UInt64 {
        generation &+= 1
        isRunning = true
        return generation
    }

    mutating func stop() {
        generation &+= 1
        isRunning = false
    }

    func accepts(_ deliveryGeneration: UInt64) -> Bool {
        isRunning && generation == deliveryGeneration
    }
}
