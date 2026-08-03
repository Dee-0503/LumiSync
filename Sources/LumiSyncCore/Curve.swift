public struct CurvePoint: Equatable, Codable, Sendable {
    public let display: Double
    public let keyboard: Double

    public init(display: Double, keyboard: Double) {
        self.display = display
        self.keyboard = keyboard
    }
}

public struct BrightnessCurve: Equatable, Codable, Sendable {
    public let points: [CurvePoint]

    public init(points: [CurvePoint]) throws {
        guard (2...16).contains(points.count) else {
            throw CurveValidationError.invalidPointCount
        }
        guard points[0] == CurvePoint(display: 0.0, keyboard: 0.0) else {
            throw CurveValidationError.invalidOrigin
        }
        guard points.allSatisfy({
            (0.0...1.0).contains($0.display) && (0.0...1.0).contains($0.keyboard)
        }) else {
            throw CurveValidationError.coordinateOutOfRange
        }
        guard zip(points, points.dropFirst()).allSatisfy({ pair in
            pair.0.display < pair.1.display
        }) else {
            throw CurveValidationError.displayCoordinatesNotStrictlyIncreasing
        }

        self.points = points
    }

    public func value(at display: Double, intensity: Double) -> Double {
        let display = display.isNaN ? 0.0 : min(max(display, 0.0), 1.0)
        let curveValue: Double

        if display <= points[0].display {
            curveValue = points[0].keyboard
        } else if display >= points[points.count - 1].display {
            curveValue = points[points.count - 1].keyboard
        } else {
            let segment = zip(points, points.dropFirst()).first {
                display <= $0.1.display
            }!
            let progress = (display - segment.0.display) / (segment.1.display - segment.0.display)
            curveValue = segment.0.keyboard + progress * (segment.1.keyboard - segment.0.keyboard)
        }

        let scaledValue = curveValue * intensity
        return scaledValue.isNaN ? 0.0 : min(max(scaledValue, 0.0), 1.0)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let points = try container.decode([CurvePoint].self, forKey: .points)

        do {
            try self.init(points: points)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .points,
                in: container,
                debugDescription: "Brightness curve points are invalid."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }

    private enum CodingKeys: String, CodingKey {
        case points
    }
}

public enum CurvePreset: String, CaseIterable, Codable, Sendable {
    case comfort
    case alwaysOn
    case energySaver

    public var curve: BrightnessCurve {
        let points: [CurvePoint]

        switch self {
        case .comfort:
            points = [
                CurvePoint(display: 0.00, keyboard: 0.00),
                CurvePoint(display: 0.01, keyboard: 1.00),
                CurvePoint(display: 0.20, keyboard: 0.75),
                CurvePoint(display: 0.40, keyboard: 0.35),
                CurvePoint(display: 0.60, keyboard: 0.00),
                CurvePoint(display: 1.00, keyboard: 0.00)
            ]
        case .alwaysOn:
            points = [
                CurvePoint(display: 0.00, keyboard: 0.00),
                CurvePoint(display: 0.01, keyboard: 1.00),
                CurvePoint(display: 0.30, keyboard: 0.70),
                CurvePoint(display: 0.60, keyboard: 0.40),
                CurvePoint(display: 1.00, keyboard: 0.20)
            ]
        case .energySaver:
            points = [
                CurvePoint(display: 0.00, keyboard: 0.00),
                CurvePoint(display: 0.01, keyboard: 0.80),
                CurvePoint(display: 0.15, keyboard: 0.45),
                CurvePoint(display: 0.30, keyboard: 0.00),
                CurvePoint(display: 1.00, keyboard: 0.00)
            ]
        }

        return try! BrightnessCurve(points: points)
    }
}

private enum CurveValidationError: Error {
    case invalidPointCount
    case invalidOrigin
    case coordinateOutOfRange
    case displayCoordinatesNotStrictlyIncreasing
}
