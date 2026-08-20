import Foundation

public enum FramedJSONError: Error, Equatable, Sendable {
    case empty
    case truncatedHeader
    case oversized
    case truncatedPayload
    case trailingBytes
}

public struct FramedJSONCodec: Sendable {
    public static let maximumPayloadBytes = 16_384
    public let maximumPayloadBytes = Self.maximumPayloadBytes

    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        guard payload.count <= maximumPayloadBytes else {
            throw FramedJSONError.oversized
        }

        let length = UInt32(payload.count)
        var frame = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff)
        ])
        frame.append(payload)
        return frame
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty else {
            throw FramedJSONError.empty
        }
        guard data.count >= 4 else {
            throw FramedJSONError.truncatedHeader
        }

        let declaredLength = Int(data[data.startIndex]) << 24
            | Int(data[data.startIndex + 1]) << 16
            | Int(data[data.startIndex + 2]) << 8
            | Int(data[data.startIndex + 3])
        guard declaredLength <= maximumPayloadBytes else {
            throw FramedJSONError.oversized
        }

        let payloadStart = data.startIndex + 4
        let actualLength = data.count - 4
        guard actualLength <= maximumPayloadBytes else {
            throw FramedJSONError.oversized
        }
        guard actualLength >= declaredLength else {
            throw FramedJSONError.truncatedPayload
        }
        guard actualLength == declaredLength else {
            throw FramedJSONError.trailingBytes
        }

        return try JSONDecoder().decode(type, from: data[payloadStart...])
    }
}
