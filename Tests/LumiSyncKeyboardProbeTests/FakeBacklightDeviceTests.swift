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
