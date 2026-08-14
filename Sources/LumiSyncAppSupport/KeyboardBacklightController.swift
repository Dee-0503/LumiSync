public enum KeyboardBacklightAvailability: String, Equatable, Sendable {
    case available
    case unavailable
}

public enum KeyboardBacklightError: Error, Equatable {
    case unavailable
}

public protocol KeyboardBacklightControlling: AnyObject {
    var availability: KeyboardBacklightAvailability { get }
    func setBrightness(_ value: Double) throws
}

public final class UnavailableKeyboardBacklightController: KeyboardBacklightControlling {
    public init() {}

    public var availability: KeyboardBacklightAvailability { .unavailable }

    public func setBrightness(_ value: Double) throws {
        throw KeyboardBacklightError.unavailable
    }
}
