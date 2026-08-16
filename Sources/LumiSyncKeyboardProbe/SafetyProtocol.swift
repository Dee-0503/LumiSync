public enum BacklightSafetyValueError: Error, Equatable, Sendable {
    case invalidNormalizedValue(Double)
    case invalidRequestID
    case invalidDeadline(UInt64)
}

public struct NormalizedBacklightValue: Codable, Equatable, Sendable {
    public let rawValue: Double

    public init(_ rawValue: Double) throws {
        guard rawValue.isFinite, (0.0...1.0).contains(rawValue) else {
            throw BacklightSafetyValueError.invalidNormalizedValue(rawValue)
        }
        self.rawValue = rawValue
    }
}

public struct BacklightRequestID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let byteCount = rawValue.utf8.count
        guard byteCount > 0, byteCount <= 64 else {
            throw BacklightSafetyValueError.invalidRequestID
        }
        self.rawValue = rawValue
    }
}

public struct BacklightDeadline: Codable, Equatable, Sendable {
    private static let maximumNanoseconds: UInt64 = 30_000_000_000

    public let remainingNanoseconds: UInt64

    public init(remainingNanoseconds: UInt64) throws {
        guard remainingNanoseconds > 0,
              remainingNanoseconds <= Self.maximumNanoseconds
        else {
            throw BacklightSafetyValueError.invalidDeadline(remainingNanoseconds)
        }
        self.remainingNanoseconds = remainingNanoseconds
    }
}

public enum BacklightOperation: Codable, Equatable, Sendable {
    case read
    case set(NormalizedBacklightValue)
    case restore(NormalizedBacklightValue)
}

public struct BacklightRequest: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let requestID: BacklightRequestID
    public let operation: BacklightOperation
    public let deadline: BacklightDeadline

    public init(
        requestID: BacklightRequestID,
        operation: BacklightOperation,
        deadline: BacklightDeadline
    ) {
        version = Self.currentVersion
        self.requestID = requestID
        self.operation = operation
        self.deadline = deadline
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID
        case operation
        case deadline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported backlight protocol version \(version)."
            )
        }
        self.version = version
        requestID = try container.decode(BacklightRequestID.self, forKey: .requestID)
        operation = try container.decode(BacklightOperation.self, forKey: .operation)
        deadline = try container.decode(BacklightDeadline.self, forKey: .deadline)
    }
}

public enum BacklightStage: String, Codable, Equatable, Sendable {
    case captureOriginal
    case write
    case writeReadback
    case restore
    case restoreReadback
}

public enum BacklightFailure: Codable, Equatable, Sendable {
    case rejected
    case timedOut(stage: BacklightStage)
    case writerFailed
    case readbackMismatch
    case restorationFailed
    case restorationUncertain
    case protocolViolation
}

public enum RestorationOutcome: Codable, Equatable, Sendable {
    case notRequired
    case verified(NormalizedBacklightValue)
    case failed
    case uncertain
}

public enum BacklightOperationResult: Codable, Equatable, Sendable {
    case success(readback: NormalizedBacklightValue)
    case failure(primary: BacklightFailure, restoration: RestorationOutcome)

    public static func resolvedFailure(
        primary: BacklightFailure?,
        restoration: RestorationOutcome
    ) -> BacklightOperationResult {
        let resolvedPrimary: BacklightFailure
        switch restoration {
        case .failed:
            resolvedPrimary = .restorationFailed
        case .uncertain:
            resolvedPrimary = .restorationUncertain
        case .notRequired, .verified:
            resolvedPrimary = primary ?? .protocolViolation
        }
        return .failure(primary: resolvedPrimary, restoration: restoration)
    }
}
