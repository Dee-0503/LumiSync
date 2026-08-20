import XCTest
@testable import LumiSyncKeyboardProbe

final class SafetyProtocolTests: XCTestCase {
    func testNormalizedBacklightValueRejectsNonFiniteAndOutOfRangeValues() throws {
        for value in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            XCTAssertThrowsError(try NormalizedBacklightValue(value))
        }

        XCTAssertEqual(try NormalizedBacklightValue(0.0).rawValue, 0.0)
        XCTAssertEqual(try NormalizedBacklightValue(0.5).rawValue, 0.5)
        XCTAssertEqual(try NormalizedBacklightValue(1.0).rawValue, 1.0)
    }

    func testRequestIDRejectsEmptyAndOversizedUTF8Values() throws {
        XCTAssertThrowsError(try BacklightRequestID(rawValue: ""))
        XCTAssertNoThrow(try BacklightRequestID(rawValue: String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try BacklightRequestID(rawValue: String(repeating: "a", count: 65)))
        XCTAssertThrowsError(try BacklightRequestID(rawValue: String(repeating: "灯", count: 22)))
    }

    func testDeadlineRejectsZeroAndValuesAboveThirtySeconds() throws {
        XCTAssertThrowsError(try BacklightDeadline(remainingNanoseconds: 0))
        XCTAssertNoThrow(try BacklightDeadline(remainingNanoseconds: 30_000_000_000))
        XCTAssertThrowsError(try BacklightDeadline(remainingNanoseconds: 30_000_000_001))
    }

    func testRequestRoundTripsThroughJSON() throws {
        let request = BacklightRequest(
            requestID: try BacklightRequestID(rawValue: "req-1"),
            operation: .set(try NormalizedBacklightValue(0.5)),
            deadline: try BacklightDeadline(remainingNanoseconds: 2_000_000_000)
        )

        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(BacklightRequest.self, from: encoded)

        XCTAssertEqual(decoded, request)
    }

    func testRequestDecoderRejectsUnknownProtocolVersion() throws {
        let request = BacklightRequest(
            requestID: try BacklightRequestID(rawValue: "req-1"),
            operation: .read,
            deadline: try BacklightDeadline(remainingNanoseconds: 2_000_000_000)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        object["version"] = 2
        let encoded = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(BacklightRequest.self, from: encoded))
    }

    func testRequestDecoderRejectsInvalidNestedSafetyValues() throws {
        let invalidObjects: [[String: Any]] = [
            [
                "version": BacklightRequest.currentVersion,
                "requestID": ["rawValue": ""],
                "operation": ["read": [:]],
                "deadline": ["remainingNanoseconds": 2_000_000_000]
            ],
            [
                "version": BacklightRequest.currentVersion,
                "requestID": ["rawValue": "req-invalid-value"],
                "operation": ["set": ["_0": ["rawValue": 2.0]]],
                "deadline": ["remainingNanoseconds": 2_000_000_000]
            ],
            [
                "version": BacklightRequest.currentVersion,
                "requestID": ["rawValue": "req-invalid-deadline"],
                "operation": ["read": [:]],
                "deadline": ["remainingNanoseconds": 30_000_000_001]
            ]
        ]

        for object in invalidObjects {
            let encoded = try JSONSerialization.data(withJSONObject: object)
            XCTAssertThrowsError(try JSONDecoder().decode(BacklightRequest.self, from: encoded))
        }
    }

    func testRestorationFailureAndUncertaintyOverridePrimaryFailure() {
        XCTAssertEqual(
            BacklightOperationResult.resolvedFailure(
                primary: .writerFailed,
                restoration: .failed
            ),
            .failure(primary: .restorationFailed, restoration: .failed)
        )
        XCTAssertEqual(
            BacklightOperationResult.resolvedFailure(
                primary: .timedOut(stage: .write),
                restoration: .uncertain
            ),
            .failure(primary: .restorationUncertain, restoration: .uncertain)
        )
        XCTAssertEqual(
            BacklightOperationResult.resolvedFailure(
                primary: .writerFailed,
                restoration: .verified(try! NormalizedBacklightValue(0.37))
            ),
            .failure(
                primary: .writerFailed,
                restoration: .verified(try! NormalizedBacklightValue(0.37))
            )
        )
    }
}
