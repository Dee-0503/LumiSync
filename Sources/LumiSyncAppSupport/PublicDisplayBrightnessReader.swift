import CoreGraphics
import Foundation
import IOKit

public struct DisplayBrightnessReading: Equatable, Sendable {
    public let value: Double
    public let sourceDescription: String
    public let fallbackReason: String?

    public init(value: Double, sourceDescription: String, fallbackReason: String? = nil) {
        self.value = min(max(value, 0), 1)
        self.sourceDescription = sourceDescription
        self.fallbackReason = fallbackReason
    }
}

public enum DisplayBrightnessError: Error, Equatable {
    case unavailable
}

public protocol DisplayBrightnessReadingService {
    func read() throws -> DisplayBrightnessReading
}

public protocol DisplayServicesAPI {
    var mainDisplayID: UInt32 { get }
    func activeDisplays() -> [UInt32]
    func isBuiltIn(_ displayID: UInt32) -> Bool
    func readBrightness(displayID: UInt32) -> Double?
}

public struct PublicDisplayBrightnessReader: DisplayBrightnessReadingService {
    private let api: any DisplayServicesAPI

    public init(api: any DisplayServicesAPI = CoreGraphicsDisplayServicesAPI()) {
        self.api = api
    }

    public func read() throws -> DisplayBrightnessReading {
        let displays = api.activeDisplays()
        let mainDisplayID = api.mainDisplayID

        if displays.contains(mainDisplayID), let brightness = api.readBrightness(displayID: mainDisplayID) {
            return DisplayBrightnessReading(
                value: brightness,
                sourceDescription: api.isBuiltIn(mainDisplayID) ? "Built-in display" : "Main display"
            )
        }

        if let displayID = displays.first(where: { api.isBuiltIn($0) && api.readBrightness(displayID: $0) != nil }),
           let brightness = api.readBrightness(displayID: displayID) {
            return DisplayBrightnessReading(
                value: brightness,
                sourceDescription: "Built-in display",
                fallbackReason: "Main display brightness is unavailable; using the built-in display."
            )
        }

        throw DisplayBrightnessError.unavailable
    }
}

public struct CoreGraphicsDisplayServicesAPI: DisplayServicesAPI {
    public init() {}

    public var mainDisplayID: UInt32 {
        CGMainDisplayID()
    }

    public func activeDisplays() -> [UInt32] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return []
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return []
        }
        return Array(displays.prefix(Int(count)))
    }

    public func isBuiltIn(_ displayID: UInt32) -> Bool {
        CGDisplayIsBuiltin(displayID) != 0
    }

    public func readBrightness(displayID: UInt32) -> Double? {
        guard let service = displayService(for: displayID) else { return nil }
        defer { IOObjectRelease(service) }

        var brightness: Float = 0
        let result = IODisplayGetFloatParameter(
            service,
            0,
            kIODisplayBrightnessKey as CFString,
            &brightness
        )
        guard result == kIOReturnSuccess, brightness.isFinite else { return nil }
        return min(max(Double(brightness), 0), 1)
    }

    private func displayService(for displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        ) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))
                .takeRetainedValue() as NSDictionary
            let vendorID = (info[kDisplayVendorID] as? NSNumber)?.uint32Value
            let productID = (info[kDisplayProductID] as? NSNumber)?.uint32Value
            let serialNumber = (info[kDisplaySerialNumber] as? NSNumber)?.uint32Value

            if vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID),
               serialNumber == CGDisplaySerialNumber(displayID) {
                return service
            }

            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return nil
    }
}

private let kDisplayVendorID = "DisplayVendorID"
private let kDisplayProductID = "DisplayProductID"
private let kDisplaySerialNumber = "DisplaySerialNumber"
