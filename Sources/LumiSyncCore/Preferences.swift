public enum CurveSelection: Equatable, Codable, Sendable {
    case preset(CurvePreset)
    case custom(BrightnessCurve)
}

public struct LumiSyncPreferences: Equatable, Codable, Sendable {
    public let version: Int
    public let curveSelection: CurveSelection
    public let intensity: Double
    public let loginLaunchEnabled: Bool
    public let excludedKeyboardDevices: Set<KeyboardDeviceID>

    public init(
        version: Int,
        curveSelection: CurveSelection,
        intensity: Double,
        loginLaunchEnabled: Bool,
        excludedKeyboardDevices: Set<KeyboardDeviceID>
    ) {
        self.version = version
        self.curveSelection = curveSelection
        self.intensity = intensity
        self.loginLaunchEnabled = loginLaunchEnabled
        self.excludedKeyboardDevices = excludedKeyboardDevices
    }

    public static let defaults = LumiSyncPreferences(
        version: 1,
        curveSelection: .preset(.comfort),
        intensity: 1.0,
        loginLaunchEnabled: true,
        excludedKeyboardDevices: []
    )
}
