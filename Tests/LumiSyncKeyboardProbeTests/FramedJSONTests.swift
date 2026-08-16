import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class FramedJSONTests: XCTestCase {
    func testCodecRoundTripsExactlyOneRequest() throws {
        let request = try makeReadRequest()
        let frame = try FramedJSONCodec().encode(request)

        XCTAssertEqual(
            try FramedJSONCodec().decode(BacklightRequest.self, from: frame),
            request
        )
    }

    func testCodecUsesFourByteBigEndianLengthPrefix() throws {
        let frame = try FramedJSONCodec().encode(try makeReadRequest())
        let payloadLength = frame.count - 4

        XCTAssertEqual(Array(frame.prefix(4)), [
            UInt8((payloadLength >> 24) & 0xff),
            UInt8((payloadLength >> 16) & 0xff),
            UInt8((payloadLength >> 8) & 0xff),
            UInt8(payloadLength & 0xff)
        ])
    }

    func testCodecRejectsOversizedAndTrailingPayloads() throws {
        var oversized = Data([0, 0, 64, 1])
        oversized.append(Data(repeating: 0, count: 16_385))
        XCTAssertThrowsError(
            try FramedJSONCodec().decode(BacklightRequest.self, from: oversized)
        ) { error in
            XCTAssertEqual(error as? FramedJSONError, .oversized)
        }

        var valid = try FramedJSONCodec().encode(try makeReadRequest())
        valid.append(0)
        XCTAssertThrowsError(
            try FramedJSONCodec().decode(BacklightRequest.self, from: valid)
        ) { error in
            XCTAssertEqual(error as? FramedJSONError, .trailingBytes)
        }
    }

    func testCodecClassifiesIncompleteFrames() throws {
        XCTAssertThrowsError(
            try FramedJSONCodec().decode(BacklightRequest.self, from: Data())
        ) { error in
            XCTAssertEqual(error as? FramedJSONError, .empty)
        }
        XCTAssertThrowsError(
            try FramedJSONCodec().decode(BacklightRequest.self, from: Data([0, 0, 0]))
        ) { error in
            XCTAssertEqual(error as? FramedJSONError, .truncatedHeader)
        }
        XCTAssertThrowsError(
            try FramedJSONCodec().decode(
                BacklightRequest.self,
                from: Data([0, 0, 0, 2, 0])
            )
        ) { error in
            XCTAssertEqual(error as? FramedJSONError, .truncatedPayload)
        }
    }

    func testCodecRejectsEncodingPayloadAboveLimit() {
        XCTAssertThrowsError(
            try FramedJSONCodec().encode(OversizedPayload(value: String(repeating: "a", count: 16_385)))
        ) { error in
            XCTAssertEqual(error as? FramedJSONError, .oversized)
        }
    }
}

private extension FramedJSONTests {
    func makeReadRequest() throws -> BacklightRequest {
        BacklightRequest(
            requestID: try BacklightRequestID(rawValue: "req-1"),
            operation: .read,
            deadline: try BacklightDeadline(remainingNanoseconds: 2_000_000_000)
        )
    }
}

private struct OversizedPayload: Encodable {
    let value: String
}
