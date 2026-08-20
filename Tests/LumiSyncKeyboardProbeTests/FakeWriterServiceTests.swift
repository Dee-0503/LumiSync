import XCTest
@testable import LumiSyncKeyboardProbe

final class FakeWriterServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testSetWritesAndReturnsVerifiedReadback() throws {
        let directory = try makeTemporaryFakeDevice(initial: 0.37)
        let request = BacklightRequest(
            requestID: try BacklightRequestID(rawValue: "writer-set"),
            operation: .set(try NormalizedBacklightValue(0.5)),
            deadline: try BacklightDeadline(remainingNanoseconds: 1_000_000_000)
        )

        let result = FakeWriterService().execute(request, deviceDirectory: directory)

        XCTAssertEqual(
            result,
            .success(readback: try NormalizedBacklightValue(0.5))
        )
        XCTAssertEqual(
            try FileBackedFakeBacklightDevice(directory: directory).read(
                requestID: try BacklightRequestID(rawValue: "verify")
            ),
            try NormalizedBacklightValue(0.5)
        )
    }

    private func makeTemporaryFakeDevice(initial: Double) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiSyncFakeWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        temporaryDirectories.append(directory)
        try FileBackedFakeBacklightDevice.create(
            directory: directory,
            configuration: FakeBacklightDeviceConfiguration(
                initialValue: try NormalizedBacklightValue(initial)
            )
        )
        return directory
    }
}
