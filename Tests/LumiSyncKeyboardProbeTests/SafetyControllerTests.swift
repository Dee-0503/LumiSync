import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class SafetyControllerTests: XCTestCase {
    func testIdenticalConcurrentRequestSharesOneSupervisorCall() async throws {
        let supervisor = BlockingSupervisor()
        let controller = BacklightSafetyController(supervisor: supervisor)

        let firstRequest = try makeSetRequest(0.5, id: "a")
        let secondRequest = try makeSetRequest(0.5, id: "b")
        async let first = controller.submit(firstRequest)
        async let second = controller.submit(secondRequest)
        await supervisor.release()
        let results = await (first, second)

        XCTAssertEqual(results.0, .success(readback: try NormalizedBacklightValue(0.5)))
        XCTAssertEqual(results.1, results.0)
        let callCount = await supervisor.callCount()
        XCTAssertEqual(callCount, 1)
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

    private func makeSetRequest(_ value: Double, id: String) throws -> BacklightRequest {
        BacklightRequest(
            requestID: try BacklightRequestID(rawValue: id),
            operation: .set(try NormalizedBacklightValue(value)),
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
