import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class SafetyControllerTests: XCTestCase {
    func testExactConcurrentRequestSharesOneSupervisorCall() async throws {
        let supervisor = BlockingSupervisor()
        let controller = BacklightSafetyController(supervisor: supervisor)

        let request = try makeSetRequest(0.5, id: "same")
        async let first = controller.submit(request)
        async let second = controller.submit(request)
        await supervisor.release()
        let results = await (first, second)

        XCTAssertEqual(results.0, .success(readback: try NormalizedBacklightValue(0.5)))
        XCTAssertEqual(results.1, results.0)
        let callCount = await supervisor.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testSameOperationWithDifferentIdentityIsRejectedBusy() async throws {
        let supervisor = BlockingSupervisor()
        let controller = BacklightSafetyController(supervisor: supervisor)

        let firstRequest = try makeSetRequest(0.5, id: "a")
        async let first = controller.submit(firstRequest)
        await supervisor.waitForCall()
        let differentID = await controller.submit(try makeSetRequest(0.5, id: "b"))
        let differentDeadline = await controller.submit(
            try makeSetRequest(0.5, id: "a", deadlineNanoseconds: 1_000_000_000)
        )
        await supervisor.release()
        _ = await first

        XCTAssertEqual(differentID, .failure(primary: .rejected, restoration: .notRequired))
        XCTAssertEqual(differentDeadline, .failure(primary: .rejected, restoration: .notRequired))
        let callCount = await supervisor.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testReadWaitsForActiveMutationBeforeEnteringSupervisor() async throws {
        let supervisor = BlockingSupervisor()
        let controller = BacklightSafetyController(supervisor: supervisor)

        let mutationRequest = try makeSetRequest(0.5, id: "set")
        let readRequest = try makeReadRequest(id: "read")
        async let mutation = controller.submit(mutationRequest)
        await supervisor.waitForCall()
        async let read = controller.submit(readRequest)
        await Task.yield()

        let activeCallCount = await supervisor.callCount()
        XCTAssertEqual(activeCallCount, 1)
        await supervisor.release()
        _ = await mutation
        _ = await read
        let finalCallCount = await supervisor.callCount()
        XCTAssertEqual(finalCallCount, 2)
    }

    func testDifferentConcurrentRequestIsRejectedBusy() async throws {
        let supervisor = BlockingSupervisor()
        let controller = BacklightSafetyController(supervisor: supervisor)

        let firstRequest = try makeSetRequest(0.5, id: "a")
        async let first = controller.submit(firstRequest)
        await supervisor.waitForCall()
        let second = await controller.submit(try makeSetRequest(0.8, id: "b"))
        await supervisor.release()
        _ = await first

        XCTAssertEqual(
            second,
            .failure(primary: .rejected, restoration: .notRequired)
        )
        let callCount = await supervisor.callCount()
        XCTAssertEqual(callCount, 1)
    }

    private func makeSetRequest(
        _ value: Double,
        id: String,
        deadlineNanoseconds: UInt64 = 2_000_000_000
    ) throws -> BacklightRequest {
        BacklightRequest(
            requestID: try BacklightRequestID(rawValue: id),
            operation: .set(try NormalizedBacklightValue(value)),
            deadline: try BacklightDeadline(remainingNanoseconds: deadlineNanoseconds)
        )
    }

    private func makeReadRequest(id: String) throws -> BacklightRequest {
        BacklightRequest(
            requestID: try BacklightRequestID(rawValue: id),
            operation: .read,
            deadline: try BacklightDeadline(remainingNanoseconds: 2_000_000_000)
        )
    }
}

private actor BlockingSupervisor: BacklightSupervising {
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func callCount() -> Int { calls }

    func waitForCall() async {
        while calls == 0 {
            await Task.yield()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func execute(_ request: BacklightRequest) async -> BacklightOperationResult {
        calls += 1
        if !released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        switch request.operation {
        case .set(let value), .restore(let value):
            return .success(readback: value)
        case .read:
            return .success(readback: try! NormalizedBacklightValue(0.37))
        }
    }
}
