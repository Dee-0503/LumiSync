/// The App-facing boundary for the privileged keyboard-backlight Helper.
///
/// A future XPC adapter will implement this interface only after the hardware
/// feasibility gate is verified. Values use the normalized range `0.0...1.0`.
public protocol LumiSyncHelperProtocol: Sendable {
    func readKeyboardBacklight() async throws -> Double
    func setKeyboardBacklight(_ value: Double) async throws
}
