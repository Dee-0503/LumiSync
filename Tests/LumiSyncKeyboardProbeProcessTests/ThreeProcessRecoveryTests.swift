import Darwin
import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class ThreeProcessRecoveryTests: XCTestCase {
    func testSetRequestTraversesControllerSupervisorWriterAndReturnsReadback() async throws {
        let harness = try ProcessHarness(initialValue: 0.37)
        let request = try harness.makeRequest(
            requestID: "normal-set",
            operation: .set(try NormalizedBacklightValue(0.5))
        )

        let result = await harness.run(
            input: try FramedJSONCodec().encode(request),
            timeout: .seconds(2)
        )

        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(
            try FramedJSONCodec().decode(BacklightOperationResult.self, from: result.stdout),
            .success(readback: try NormalizedBacklightValue(0.5))
        )
        let journalEntries = try harness.journalEntries()
        XCTAssertEqual(try harness.currentValue(), try NormalizedBacklightValue(0.37))
        XCTAssertEqual(
            journalEntries.map { "\($0.processRole.rawValue):\($0.operationCategory.rawValue):\($0.value.rawValue)" },
            [
                "writer:read:0.37",
                "writer:set:0.5",
                "writer:read:0.5",
                "writer:restore:0.37",
                "writer:read:0.37"
            ]
        )
    }

    func testMalformedInputIsRejectedWithoutMutation() async throws {
        let harness = try ProcessHarness()
        let result = await harness.run(input: Data(), timeout: .seconds(2))
        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(
            try FramedJSONCodec().decode(BacklightOperationResult.self, from: result.stdout),
            .failure(primary: .protocolViolation, restoration: .notRequired)
        )
        XCTAssertEqual(try harness.currentValue(), try NormalizedBacklightValue(0.37))
    }

    func testStageTimeoutMatrixIsContainedAndReportsRestorationCertainty() throws {
        for stage in [
            BacklightStage.captureOriginal,
            .write,
            .writeReadback,
            .restore,
            .restoreReadback
        ] {
            let harness = try ProcessHarness(initialValue: 0.37, pausedAt: stage)
            let request = try harness.makeRequest(
                requestID: "stage-timeout-\(stage.rawValue)",
                operation: .set(try NormalizedBacklightValue(0.5)),
                deadlineNanoseconds: 1_500_000_000
            )
            let started = ContinuousClock.now
            let scenario = try harness.startScenario(
                input: try FramedJSONCodec().encode(request),
                outerTimeout: .seconds(5)
            )

            let processResult = try scenario.finish()
            let elapsed = started.duration(to: .now)
            XCTAssertLessThan(elapsed, .seconds(5), "stage=\(stage.rawValue)")
            XCTAssertEqual(processResult.termination, .exited, "stage=\(stage.rawValue)")
            let result = try FramedJSONCodec().decode(
                BacklightOperationResult.self,
                from: processResult.stdout
            )
            let entries = try scenario.journalEntries()
                .filter { $0.processRole == .writer }

            switch stage {
            case .captureOriginal:
                XCTAssertEqual(
                    result,
                    .failure(
                        primary: .timedOut(stage: .captureOriginal),
                        restoration: .notRequired
                    )
                )
                XCTAssertFalse(entries.contains { $0.operationCategory == .set })
                XCTAssertFalse(entries.contains { $0.operationCategory == .restore })
                XCTAssertEqual(try scenario.currentValue(), try NormalizedBacklightValue(0.37))
            case .write:
                XCTAssertEqual(
                    result,
                    .failure(
                        primary: .timedOut(stage: .write),
                        restoration: .verified(try NormalizedBacklightValue(0.37))
                    )
                )
                XCTAssertFalse(entries.contains { $0.operationCategory == .set })
                XCTAssertTrue(entries.contains { $0.operationCategory == .restore })
                XCTAssertEqual(try scenario.currentValue(), try NormalizedBacklightValue(0.37))
            case .writeReadback:
                XCTAssertEqual(
                    result,
                    .failure(
                        primary: .timedOut(stage: .writeReadback),
                        restoration: .verified(try NormalizedBacklightValue(0.37))
                    )
                )
                XCTAssertTrue(entries.contains { $0.operationCategory == .set })
                XCTAssertTrue(entries.contains { $0.operationCategory == .restore })
                XCTAssertEqual(try scenario.currentValue(), try NormalizedBacklightValue(0.37))
            case .restore:
                XCTAssertEqual(
                    result,
                    .failure(primary: .restorationFailed, restoration: .failed)
                )
                XCTAssertFalse(entries.contains { $0.operationCategory == .restore })
                XCTAssertEqual(try scenario.currentValue(), try NormalizedBacklightValue(0.5))
            case .restoreReadback:
                XCTAssertEqual(
                    result,
                    .failure(primary: .restorationUncertain, restoration: .uncertain)
                )
                XCTAssertTrue(entries.contains { $0.operationCategory == .restore })
                XCTAssertEqual(try scenario.currentValue(), try NormalizedBacklightValue(0.37))
            }
            try scenario.assertNoOwnedProcessesRemain()
        }
    }

    func testControllerSignalsLeaveSupervisorToRestoreOriginalValue() throws {
        for signal in [SIGINT, SIGTERM, SIGABRT, SIGKILL] {
            let harness = try ProcessHarness(initialValue: 0.37, pausedAt: .writeReadback)
            let request = try harness.makeRequest(
                requestID: "controller-signal-\(signal)",
                operation: .set(try NormalizedBacklightValue(0.5))
            )
            let scenario = try harness.startScenario(
                input: try FramedJSONCodec().encode(request),
                outerTimeout: .seconds(5)
            )

            try scenario.waitForJournalEvent {
                $0.processRole == .writer && $0.operationCategory == .set
            }
            try scenario.signalOwnedRole(.controller, signal)
            let result = try scenario.finish()

            XCTAssertEqual(result.termination, .signaled(signal), "signal=\(signal)")
            XCTAssertEqual(
                try scenario.currentValue(),
                try NormalizedBacklightValue(0.37),
                "signal=\(signal)"
            )
            let operationCategories = try scenario.journalEntries()
                .filter { $0.processRole == .writer }
                .map(\.operationCategory)
            XCTAssertTrue(operationCategories.contains(.restore), "signal=\(signal)")
            XCTAssertEqual(operationCategories.last, .read, "signal=\(signal)")
            try scenario.assertNoOwnedProcessesRemain()
        }
    }

    func testWriterSignalsRestoreOriginalValue() throws {
        for signal in [SIGINT, SIGTERM, SIGABRT, SIGKILL] {
            let harness = try ProcessHarness(initialValue: 0.37, pausedAt: .writeReadback)
            let request = try harness.makeRequest(
                requestID: "writer-signal-\(signal)",
                operation: .set(try NormalizedBacklightValue(0.5))
            )
            let scenario = try harness.startScenario(
                input: try FramedJSONCodec().encode(request),
                outerTimeout: .seconds(5)
            )

            try scenario.waitForJournalEvent {
                $0.processRole == .writer && $0.operationCategory == .set
            }
            try scenario.signalOwnedRole(.writer, signal)
            let result = try scenario.finish()

            XCTAssertEqual(result.termination, .exited, "signal=\(signal)")
            XCTAssertEqual(
                try FramedJSONCodec().decode(BacklightOperationResult.self, from: result.stdout),
                .failure(
                    primary: .writerFailed,
                    restoration: .verified(try NormalizedBacklightValue(0.37))
                ),
                "signal=\(signal)"
            )
            XCTAssertEqual(
                try scenario.currentValue(),
                try NormalizedBacklightValue(0.37),
                "signal=\(signal)"
            )
            try scenario.assertNoOwnedProcessesRemain()
        }
    }
}
