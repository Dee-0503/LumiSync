import Darwin
import Foundation

public enum FramedJSONError: Error, Equatable, Sendable {
    case empty
    case truncatedHeader
    case oversized
    case truncatedPayload
    case trailingBytes
    case timedOut
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

public struct FramedJSONReader: Sendable {
    public static let defaultTimeout: Duration = .seconds(1)

    private let codec: FramedJSONCodec

    public init(codec: FramedJSONCodec = FramedJSONCodec()) {
        self.codec = codec
    }

    public func read<T: Decodable>(
        _ type: T.Type,
        from fileHandle: FileHandle,
        timeout: Duration = Self.defaultTimeout
    ) throws -> T {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let header = try readExactly(
            4,
            from: fileHandle.fileDescriptor,
            deadline: deadline,
            emptyError: .empty,
            partialError: .truncatedHeader
        )
        let declaredLength = Int(header[header.startIndex]) << 24
            | Int(header[header.startIndex + 1]) << 16
            | Int(header[header.startIndex + 2]) << 8
            | Int(header[header.startIndex + 3])
        guard declaredLength <= codec.maximumPayloadBytes else {
            throw FramedJSONError.oversized
        }
        let payload = try readExactly(
            declaredLength,
            from: fileHandle.fileDescriptor,
            deadline: deadline,
            emptyError: .truncatedPayload,
            partialError: .truncatedPayload
        )
        try rejectTrailingByte(from: fileHandle.fileDescriptor)
        return try codec.decode(type, from: header + payload)
    }

    private func readExactly(
        _ count: Int,
        from descriptor: Int32,
        deadline: ContinuousClock.Instant,
        emptyError: FramedJSONError,
        partialError: FramedJSONError
    ) throws -> Data {
        var result = Data()
        while result.count < count {
            try waitUntilReadable(descriptor, deadline: deadline)
            var buffer = [UInt8](repeating: 0, count: count - result.count)
            let bytesRead = Darwin.read(descriptor, &buffer, buffer.count)
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            if bytesRead == 0 {
                throw result.isEmpty ? emptyError : partialError
            }
            result.append(buffer, count: bytesRead)
        }
        return result
    }

    private func rejectTrailingByte(from descriptor: Int32) throws {
        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let result = poll(&pollDescriptor, 1, 0)
            if result < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            guard result > 0, pollDescriptor.revents & Int16(POLLIN) != 0 else {
                return
            }
            var byte: UInt8 = 0
            let bytesRead = Darwin.read(descriptor, &byte, 1)
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            if bytesRead > 0 {
                throw FramedJSONError.trailingBytes
            }
            return
        }
    }

    private func waitUntilReadable(
        _ descriptor: Int32,
        deadline: ContinuousClock.Instant
    ) throws {
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw FramedJSONError.timedOut
            }
            let components = remaining.components
            let milliseconds = max(
                1,
                min(
                    1_000,
                    Int32(clamping: components.seconds * 1_000)
                        + Int32(clamping: components.attoseconds / 1_000_000_000_000_000)
                )
            )
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let result = poll(&pollDescriptor, 1, milliseconds)
            if result < 0 {
                if errno == EINTR { continue }
                throw CocoaError(.fileReadUnknown)
            }
            if result == 0 { continue }
            return
        }
    }
}
