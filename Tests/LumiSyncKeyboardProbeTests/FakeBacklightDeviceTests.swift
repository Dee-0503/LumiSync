import Darwin
import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class FakeBacklightDeviceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testWriteAndReadPersistAcrossDeviceInstances() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let requestID = try BacklightRequestID(rawValue: "req-1")

        try FileBackedFakeBacklightDevice(directory: directory).write(
            try NormalizedBacklightValue(0.5),
            requestID: requestID
        )

        XCTAssertEqual(
            try FileBackedFakeBacklightDevice(directory: directory).read(requestID: requestID),
            try NormalizedBacklightValue(0.5)
        )
        let entries = try FileBackedFakeBacklightDevice(directory: directory).journalEntries()
        XCTAssertEqual(entries.map(\.sequenceNumber), [1, 2])
        XCTAssertEqual(entries.map(\.operationCategory), [.set, .read])
        XCTAssertEqual(entries.map(\.requestID), [requestID, requestID])
        XCTAssertTrue(entries.allSatisfy { $0.processID == getpid() })
    }

    func testReadRecoversDurablePrepareBeforeAppendingReadRecord() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let failedDevice = try FileBackedFakeBacklightDevice(
            directory: directory,
            systemCalls: ScriptedFakeBacklightSystemCalls(
                failures: [.fsync(.stateFile)]
            )
        )
        let failedID = try BacklightRequestID(rawValue: "prepare-before-read")
        XCTAssertThrowsError(
            try failedDevice.write(
                try NormalizedBacklightValue(0.5),
                requestID: failedID
            )
        )

        let readID = try BacklightRequestID(rawValue: "recovery-read")
        let device = try FileBackedFakeBacklightDevice(directory: directory)
        XCTAssertEqual(
            try device.read(requestID: readID),
            try NormalizedBacklightValue(0.37)
        )

        let records = try rawJournalRecords(in: directory)
        XCTAssertEqual(records.map(\.phase), [.prepare, .abort, .commit])
        XCTAssertEqual(records.map(\.sequenceNumber), [1, 1, 2])
        XCTAssertEqual(try device.journalEntries().map(\.requestID), [readID])
    }

    func testWriteLeavesStateAndJournalUnchangedWhenJournalAppendFails() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let requestID = try BacklightRequestID(rawValue: "journal-full")
        let existingEntry = FakeBacklightJournalEntry(
            sequenceNumber: 1,
            requestID: requestID,
            processRole: .test,
            operationCategory: .read,
            value: try NormalizedBacklightValue(0.37),
            processID: getpid()
        )
        var existingRecord = try JSONEncoder().encode(existingEntry)
        existingRecord.append(0x0A)
        var existingJournal = Data(
            repeating: 0x20,
            count: FileBackedFakeBacklightDevice.maximumJournalBytes - existingRecord.count
        )
        existingJournal[existingJournal.index(before: existingJournal.endIndex)] = 0x0A
        existingJournal.append(existingRecord)
        let journalURL = directory.appendingPathComponent("journal.jsonl")
        try existingJournal.write(to: journalURL)

        let stateURL = directory.appendingPathComponent("state.json")
        let originalState = try Data(contentsOf: stateURL)
        let originalJournal = try Data(contentsOf: journalURL)

        XCTAssertThrowsError(
            try FileBackedFakeBacklightDevice(directory: directory).write(
                try NormalizedBacklightValue(0.5),
                requestID: requestID
            )
        )

        XCTAssertEqual(try Data(contentsOf: stateURL), originalState)
        XCTAssertEqual(try Data(contentsOf: journalURL), originalJournal)
    }

    func testFaultActionsAreConsumedInOrder() throws {
        let directory = try makeTemporaryFakeDevice(
            initial: 0.37,
            faults: [
                .sleepNanoseconds(1),
                .returnValue(try NormalizedBacklightValue(0.25))
            ]
        )
        let device = try FileBackedFakeBacklightDevice(directory: directory)

        XCTAssertEqual(try device.consumeFault(), .sleepNanoseconds(1))
        XCTAssertEqual(
            try device.consumeFault(),
            .returnValue(try NormalizedBacklightValue(0.25))
        )
        XCTAssertNil(try device.consumeFault())
    }

    func testConsumeFaultLeavesFaultsUnchangedWhenReplacementFails() throws {
        let directory = try makeTemporaryFakeDevice(
            initial: 0.37,
            faults: [.sleepNanoseconds(1)]
        )
        let faultsURL = directory.appendingPathComponent("faults.json")
        let originalFaults = try Data(contentsOf: faultsURL)
        let temporary = directory.appendingPathComponent(".faults.json.tmp")
        try FileManager.default.createSymbolicLink(
            at: temporary,
            withDestinationURL: directory.appendingPathComponent("target.json")
        )

        XCTAssertThrowsError(
            try FileBackedFakeBacklightDevice(directory: directory).consumeFault()
        )
        XCTAssertEqual(try Data(contentsOf: faultsURL), originalFaults)
    }

    func testConfigurationRoundTripsEveryFaultAction() throws {
        let configuration = FakeBacklightDeviceConfiguration(
            initialValue: try NormalizedBacklightValue(0.37),
            faultActions: [
                .returnValue(try NormalizedBacklightValue(0.25)),
                .sleepNanoseconds(1),
                .exit(code: 70),
                .raise(signal: SIGTERM),
                .malformedOutput,
                .forkSleepingChild,
                .attemptSetsid
            ]
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                FakeBacklightDeviceConfiguration.self,
                from: JSONEncoder().encode(configuration)
            ),
            configuration
        )
    }

    func testSymlinkedStateFileIsRejectedBeforeMutation() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let state = directory.appendingPathComponent("state.json")
        let target = directory.appendingPathComponent("target.json")
        try FileManager.default.moveItem(at: state, to: target)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: target)

        XCTAssertThrowsError(try FileBackedFakeBacklightDevice(directory: directory))
        XCTAssertEqual(
            try JSONDecoder().decode(
                NormalizedBacklightValue.self,
                from: Data(contentsOf: target)
            ),
            try NormalizedBacklightValue(0.37)
        )
    }

    func testInvalidStateValuesAreRejectedBeforeJournaling() throws {
        for invalidJSON in ["{\"rawValue\":1e999}", "{\"rawValue\":1.5}"] {
            let directory = try makeTemporaryFakeDevice(initial: 0.37)
            let state = directory.appendingPathComponent("state.json")
            try Data(invalidJSON.utf8).write(to: state)
            let device = try FileBackedFakeBacklightDevice(directory: directory)

            XCTAssertThrowsError(
                try device.read(requestID: BacklightRequestID(rawValue: "invalid-state"))
            )
            XCTAssertEqual(try device.journalEntries(), [])
        }
    }

    func testOversizedFaultFileIsRejectedBeforeConsumption() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let faults = directory.appendingPathComponent("faults.json")
        try Data(
            repeating: 0x20,
            count: FileBackedFakeBacklightDevice.maximumFaultFileBytes + 1
        ).write(to: faults)
        let device = try FileBackedFakeBacklightDevice(directory: directory)

        XCTAssertThrowsError(try device.consumeFault())
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: faults.path)[.size] as? Int,
            FileBackedFakeBacklightDevice.maximumFaultFileBytes + 1
        )
    }

    func testUnknownFaultCaseIsRejectedBeforeConsumption() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let faults = directory.appendingPathComponent("faults.json")
        let unknown = Data("[{\"unknownFutureFault\":{}}]".utf8)
        try unknown.write(to: faults)
        let device = try FileBackedFakeBacklightDevice(directory: directory)

        XCTAssertThrowsError(try device.consumeFault())
        XCTAssertEqual(try Data(contentsOf: faults), unknown)
    }

    func testPrepareSyncFailureDoesNotCommitState() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let systemCalls = ScriptedFakeBacklightSystemCalls(
            failures: [.fsync(.journalPrepare)]
        )
        let device = try FileBackedFakeBacklightDevice(
            directory: directory,
            systemCalls: systemCalls
        )

        XCTAssertThrowsError(
            try device.write(
                try NormalizedBacklightValue(0.5),
                requestID: try BacklightRequestID(rawValue: "prepare-sync-failure")
            )
        )

        XCTAssertEqual(try persistedValue(in: directory), try NormalizedBacklightValue(0.37))
        XCTAssertEqual(
            try FileBackedFakeBacklightDevice(directory: directory).journalEntries(),
            []
        )
    }

    func testCommitSyncFailureRecoversCommittedStateWithoutRollback() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let systemCalls = ScriptedFakeBacklightSystemCalls(
            failures: [.fsync(.journalCommit)]
        )
        let requestID = try BacklightRequestID(rawValue: "commit-sync-failure")
        let device = try FileBackedFakeBacklightDevice(
            directory: directory,
            systemCalls: systemCalls
        )

        XCTAssertThrowsError(
            try device.write(
                try NormalizedBacklightValue(0.5),
                requestID: requestID
            )
        )

        XCTAssertEqual(try persistedValue(in: directory), try NormalizedBacklightValue(0.5))
        let entries = try FileBackedFakeBacklightDevice(directory: directory).journalEntries()
        XCTAssertEqual(entries.map(\.requestID), [requestID])
        XCTAssertEqual(entries.map(\.operationCategory), [.set])
        XCTAssertEqual(entries.map(\.sequenceNumber), [1])
    }

    func testPartialCommitTailIsRepairedAndRecovered() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let systemCalls = ScriptedFakeBacklightSystemCalls(
            failures: [.partialWrite(.journalCommit, bytes: 12)]
        )
        let requestID = try BacklightRequestID(rawValue: "partial-commit")
        let device = try FileBackedFakeBacklightDevice(
            directory: directory,
            systemCalls: systemCalls
        )

        XCTAssertThrowsError(
            try device.write(
                try NormalizedBacklightValue(0.5),
                requestID: requestID
            )
        )

        let recovered = try FileBackedFakeBacklightDevice(directory: directory)
        XCTAssertEqual(try recovered.journalEntries().map(\.requestID), [requestID])
        XCTAssertEqual(try persistedValue(in: directory), try NormalizedBacklightValue(0.5))
        XCTAssertTrue(try Data(contentsOf: directory.appendingPathComponent("journal.jsonl")).last == 0x0A)
    }

    func testHistoricalJournalEntriesRemainReadableAfterTransactionalWrite() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let historicalID = try BacklightRequestID(rawValue: "historical")
        let historicalEntry = FakeBacklightJournalEntry(
            sequenceNumber: 1,
            requestID: historicalID,
            processRole: .test,
            operationCategory: .read,
            value: try NormalizedBacklightValue(0.37),
            processID: getpid()
        )
        var historicalRecord = try JSONEncoder().encode(historicalEntry)
        historicalRecord.append(0x0A)
        try historicalRecord.write(
            to: directory.appendingPathComponent("journal.jsonl")
        )

        let currentID = try BacklightRequestID(rawValue: "current")
        try FileBackedFakeBacklightDevice(directory: directory).write(
            try NormalizedBacklightValue(0.5),
            requestID: currentID
        )

        let entries = try FileBackedFakeBacklightDevice(directory: directory).journalEntries()
        XCTAssertEqual(entries.map(\.requestID), [historicalID, currentID])
        XCTAssertEqual(entries.map(\.sequenceNumber), [1, 2])
    }

    func testCompleteCorruptJournalLineFailsClosedWithoutMutation() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let journalURL = directory.appendingPathComponent("journal.jsonl")
        try Data("not-json\n".utf8).write(to: journalURL)
        let originalState = try Data(contentsOf: directory.appendingPathComponent("state.json"))

        XCTAssertThrowsError(
            try FileBackedFakeBacklightDevice(directory: directory).write(
                try NormalizedBacklightValue(0.5),
                requestID: try BacklightRequestID(rawValue: "corrupt-journal")
            )
        )

        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("state.json")),
            originalState
        )
        XCTAssertEqual(try Data(contentsOf: journalURL), Data("not-json\n".utf8))
    }

    func testPrepareOnlyPreviousStateIsAbortedAndDoesNotBlockNextWrite() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let firstID = try BacklightRequestID(rawValue: "state-sync-failure")
        let failedDevice = try FileBackedFakeBacklightDevice(
            directory: directory,
            systemCalls: ScriptedFakeBacklightSystemCalls(
                failures: [.fsync(.stateFile)]
            )
        )

        XCTAssertThrowsError(
            try failedDevice.write(
                try NormalizedBacklightValue(0.5),
                requestID: firstID
            )
        )
        XCTAssertEqual(try persistedValue(in: directory), try NormalizedBacklightValue(0.37))

        let secondID = try BacklightRequestID(rawValue: "after-abort")
        try FileBackedFakeBacklightDevice(directory: directory).write(
            try NormalizedBacklightValue(0.6),
            requestID: secondID
        )

        let records = try rawJournalRecords(in: directory)
        XCTAssertEqual(records.map(\.phase), [.prepare, .abort, .prepare, .commit])
        XCTAssertEqual(records.map(\.sequenceNumber), [1, 1, 2, 2])
        XCTAssertEqual(
            try FileBackedFakeBacklightDevice(directory: directory)
                .journalEntries()
                .map(\.requestID),
            [secondID]
        )
    }

    func testNoOpPartialCommitTailRecoversAsCommittedOperation() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let requestID = try BacklightRequestID(rawValue: "no-op-partial-commit")
        let device = try FileBackedFakeBacklightDevice(
            directory: directory,
            systemCalls: ScriptedFakeBacklightSystemCalls(
                failures: [.partialWrite(.journalCommit, bytes: 12)]
            )
        )

        XCTAssertThrowsError(
            try device.write(
                try NormalizedBacklightValue(0.37),
                requestID: requestID
            )
        )

        let recovered = try FileBackedFakeBacklightDevice(directory: directory)
        XCTAssertEqual(try recovered.journalEntries().map(\.requestID), [requestID])
        XCTAssertEqual(try persistedValue(in: directory), try NormalizedBacklightValue(0.37))
    }

    func testPartialPrepareTailIsRepairedBeforeNextWrite() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let failedDevice = try FileBackedFakeBacklightDevice(
            directory: directory,
            systemCalls: ScriptedFakeBacklightSystemCalls(
                failures: [.partialWrite(.journalPrepare, bytes: 12)]
            )
        )

        XCTAssertThrowsError(
            try failedDevice.write(
                try NormalizedBacklightValue(0.5),
                requestID: try BacklightRequestID(rawValue: "partial-prepare")
            )
        )

        let requestID = try BacklightRequestID(rawValue: "after-partial-prepare")
        try FileBackedFakeBacklightDevice(directory: directory).write(
            try NormalizedBacklightValue(0.6),
            requestID: requestID
        )

        let entries = try FileBackedFakeBacklightDevice(directory: directory).journalEntries()
        XCTAssertEqual(entries.map(\.requestID), [requestID])
        XCTAssertEqual(entries.map(\.sequenceNumber), [1])
    }

    func testRenameFailureIsAbortedBeforeNextWrite() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let failedDevice = try FileBackedFakeBacklightDevice(
            directory: directory,
            systemCalls: ScriptedFakeBacklightSystemCalls(failures: [.rename])
        )

        XCTAssertThrowsError(
            try failedDevice.write(
                try NormalizedBacklightValue(0.5),
                requestID: try BacklightRequestID(rawValue: "rename-failure")
            )
        )
        XCTAssertEqual(try persistedValue(in: directory), try NormalizedBacklightValue(0.37))

        let requestID = try BacklightRequestID(rawValue: "after-rename-failure")
        try FileBackedFakeBacklightDevice(directory: directory).write(
            try NormalizedBacklightValue(0.6),
            requestID: requestID
        )
        XCTAssertEqual(
            try FileBackedFakeBacklightDevice(directory: directory)
                .journalEntries()
                .map(\.requestID),
            [requestID]
        )
    }

    func testDirectorySyncFailureRecoversCommittedState() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let requestID = try BacklightRequestID(rawValue: "directory-sync-failure")
        let failedDevice = try FileBackedFakeBacklightDevice(
            directory: directory,
            systemCalls: ScriptedFakeBacklightSystemCalls(
                failures: [.fsync(.stateDirectory)]
            )
        )

        XCTAssertThrowsError(
            try failedDevice.write(
                try NormalizedBacklightValue(0.5),
                requestID: requestID
            )
        )

        XCTAssertEqual(try persistedValue(in: directory), try NormalizedBacklightValue(0.5))
        XCTAssertEqual(
            try FileBackedFakeBacklightDevice(directory: directory)
                .journalEntries()
                .map(\.requestID),
            [requestID]
        )
    }

    func testTailRepairFailureReportsError() throws {
        for failure in [
            ScriptedFakeBacklightSystemCalls.Failure.ftruncate,
            .fsync(.journalTailRepair)
        ] {
            let directory = try makeTemporaryFakeDevice(initial: 0.37)
            let writer = try FileBackedFakeBacklightDevice(
                directory: directory,
                systemCalls: ScriptedFakeBacklightSystemCalls(
                    failures: [.partialWrite(.journalCommit, bytes: 12)]
                )
            )
            XCTAssertThrowsError(
                try writer.write(
                    try NormalizedBacklightValue(0.5),
                    requestID: try BacklightRequestID(rawValue: "partial-commit")
                )
            )

            let recovering = try FileBackedFakeBacklightDevice(
                directory: directory,
                systemCalls: ScriptedFakeBacklightSystemCalls(failures: [failure])
            )
            XCTAssertThrowsError(try recovering.journalEntries())
        }
    }

    func testMultipleUnresolvedPreparesFailClosedWithoutMutation() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let previousValue = try NormalizedBacklightValue(0.37)
        let first = FakeBacklightJournalEntry(
            sequenceNumber: 1,
            requestID: try BacklightRequestID(rawValue: "first-prepare"),
            processRole: .test,
            operationCategory: .set,
            value: try NormalizedBacklightValue(0.5),
            processID: getpid(),
            phase: .prepare,
            previousValue: previousValue
        )
        let second = FakeBacklightJournalEntry(
            sequenceNumber: 2,
            requestID: try BacklightRequestID(rawValue: "second-prepare"),
            processRole: .test,
            operationCategory: .set,
            value: try NormalizedBacklightValue(0.6),
            processID: getpid(),
            phase: .prepare,
            previousValue: previousValue
        )
        var journal = try JSONEncoder().encode(first)
        journal.append(0x0A)
        journal.append(try JSONEncoder().encode(second))
        journal.append(0x0A)
        let journalURL = directory.appendingPathComponent("journal.jsonl")
        try journal.write(to: journalURL)
        let originalState = try Data(contentsOf: directory.appendingPathComponent("state.json"))

        XCTAssertThrowsError(
            try FileBackedFakeBacklightDevice(directory: directory).write(
                try NormalizedBacklightValue(0.7),
                requestID: try BacklightRequestID(rawValue: "blocked")
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("state.json")),
            originalState
        )
        XCTAssertEqual(try Data(contentsOf: journalURL), journal)
    }

    private func rawJournalRecords(in directory: URL) throws -> [FakeBacklightJournalEntry] {
        let data = try Data(contentsOf: directory.appendingPathComponent("journal.jsonl"))
        return try data.split(separator: 0x0A).map {
            try JSONDecoder().decode(FakeBacklightJournalEntry.self, from: Data($0))
        }
    }

    private func persistedValue(in directory: URL) throws -> NormalizedBacklightValue {
        try JSONDecoder().decode(
            NormalizedBacklightValue.self,
            from: Data(contentsOf: directory.appendingPathComponent("state.json"))
        )
    }

    private func makeTemporaryFakeDevice(
        initial: Double,
        faults: [FakeBacklightFaultAction] = []
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiSyncFakeDevice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        temporaryDirectories.append(directory)
        try FileBackedFakeBacklightDevice.create(
            directory: directory,
            configuration: FakeBacklightDeviceConfiguration(
                initialValue: try NormalizedBacklightValue(initial),
                faultActions: faults
            )
        )
        return directory
    }
}

private final class ScriptedFakeBacklightSystemCalls: FakeBacklightSystemCalling, @unchecked Sendable {
    enum Failure: Equatable {
        case fsync(FakeBacklightSyncPurpose)
        case partialWrite(FakeBacklightWritePurpose, bytes: Int)
        case rename
        case ftruncate
    }

    private var failures: [Failure]
    private var writePurposes: [Int32: FakeBacklightWritePurpose] = [:]
    private let lock = NSLock()

    init(failures: [Failure]) {
        self.failures = failures
    }

    func beginWrite(_ purpose: FakeBacklightWritePurpose, descriptor: Int32) {
        lock.withLock {
            writePurposes[descriptor] = purpose
        }
    }

    func endWrite(descriptor: Int32) {
        lock.withLock {
            writePurposes[descriptor] = nil
        }
    }

    func write(_ descriptor: Int32, buffer: UnsafeRawPointer, count: Int) -> Int {
        let scripted: Failure? = lock.withLock {
            guard let purpose = writePurposes[descriptor],
                  let index = failures.firstIndex(where: {
                      if case .partialWrite(let expected, _) = $0 {
                          return expected == purpose
                      }
                      return false
                  }) else {
                return nil
            }
            return failures.remove(at: index)
        }
        if let scripted, case .partialWrite(_, let bytes) = scripted {
            _ = Darwin.write(descriptor, buffer, min(bytes, count))
            errno = EIO
            return -1
        }
        return Darwin.write(descriptor, buffer, count)
    }

    func fsync(_ descriptor: Int32, purpose: FakeBacklightSyncPurpose) -> Int32 {
        let shouldFail = lock.withLock {
            guard let index = failures.firstIndex(of: .fsync(purpose)) else {
                return false
            }
            failures.remove(at: index)
            return true
        }
        if shouldFail {
            errno = EIO
            return -1
        }
        return Darwin.fsync(descriptor)
    }

    func rename(_ source: String, _ destination: String) -> Int32 {
        let shouldFail = lock.withLock {
            guard let index = failures.firstIndex(of: .rename) else {
                return false
            }
            failures.remove(at: index)
            return true
        }
        if shouldFail {
            errno = EIO
            return -1
        }
        return Darwin.rename(source, destination)
    }

    func ftruncate(_ descriptor: Int32, length: off_t) -> Int32 {
        let shouldFail = lock.withLock {
            guard let index = failures.firstIndex(of: .ftruncate) else {
                return false
            }
            failures.remove(at: index)
            return true
        }
        if shouldFail {
            errno = EIO
            return -1
        }
        return Darwin.ftruncate(descriptor, length)
    }
}
