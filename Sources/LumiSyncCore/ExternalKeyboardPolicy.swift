public struct KeyboardDeviceID: Hashable, Codable, Sendable {
    public let transport: String
    public let vendorID: Int
    public let productID: Int
    public let locationID: Int?

    public init(transport: String, vendorID: Int, productID: Int, locationID: Int?) {
        self.transport = transport
        self.vendorID = vendorID
        self.productID = productID
        self.locationID = locationID
    }
}

public enum KeyboardInputOrigin: Equatable, Sendable {
    case builtIn
    case external(KeyboardDeviceID)
}

public struct ExternalKeyboardPolicy: Sendable {
    private static let inactivityTimeoutSeconds = 900

    private let excludedDevices: Set<KeyboardDeviceID>
    private var lastExternalInputSeconds: Int?

    public init(excludedDevices: Set<KeyboardDeviceID>) {
        self.excludedDevices = excludedDevices
    }

    public mutating func recordInput(_ origin: KeyboardInputOrigin, seconds: Int) {
        switch origin {
        case .builtIn:
            lastExternalInputSeconds = nil
        case let .external(device):
            guard !excludedDevices.contains(device) else { return }
            lastExternalInputSeconds = seconds
        }
    }

    public mutating func tick(seconds: Int) {
        guard let lastExternalInputSeconds,
              seconds >= lastExternalInputSeconds,
              seconds - lastExternalInputSeconds >= Self.inactivityTimeoutSeconds else {
            return
        }

        self.lastExternalInputSeconds = nil
    }

    public var isExternalKeyboardActive: Bool {
        lastExternalInputSeconds != nil
    }
}
