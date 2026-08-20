import Darwin
import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class BoundedProcessTests: XCTestCase {
    private var runner: BoundedOwnedProcessRunner!

    override func setUp() {
        super.setUp()
        runner = BoundedOwnedProcessRunner()
    }

    func testRunnerCapturesBoundedOutputAndExitStatus() async {
        let result = await runner.run(
            fixture(command: "printf ok; exit 7", timeout: .seconds(1))
        )

        XCTAssertEqual(result.exitStatus, 7)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "ok")
        XCTAssertEqual(result.termination, .exited)
        XCTAssertTrue(result.cleanupVerified)
    }

    func testRunnerResetsInheritedIgnoredTerminationSignals() async {
        let previousINT = Darwin.signal(SIGINT, SIG_IGN)
        let previousTERM = Darwin.signal(SIGTERM, SIG_IGN)
        let previousABRT = Darwin.signal(SIGABRT, SIG_IGN)
        defer {
            _ = Darwin.signal(SIGINT, previousINT)
            _ = Darwin.signal(SIGTERM, previousTERM)
            _ = Darwin.signal(SIGABRT, previousABRT)
        }

        for signal in [SIGINT, SIGTERM, SIGABRT] {
            let result = await runner.run(
                fixture(
                    command: "kill -\(signal) $$; sleep 30",
                    timeout: .milliseconds(250)
                )
            )

            XCTAssertEqual(result.termination, .signaled(signal), "signal=\(signal)")
            XCTAssertTrue(result.cleanupVerified, "signal=\(signal)")
        }
    }

    func testRunnerKillsProcessGroupAtMonotonicDeadline() async {
        let result = await runner.run(
            fixture(command: "sleep 30", timeout: .milliseconds(100))
        )

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertTrue(result.cleanupVerified)
    }

    func testRunnerKillsKnownSleepingDescendantOnTimeout() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumisync-descendant-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let result = await runner.run(
            fixture(
                command: "sleep 30 & child=$!; printf '%s' $child > \(pidFile.path); wait",
                timeout: .milliseconds(150)
            )
        )

        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertTrue(result.cleanupVerified)
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertTrue(waitUntilGone(pid))
    }

    func testRunnerRejectsSetsidEscapeWhenDescendantSurvives() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumisync-setsid-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let result = await runner.run(
            fixture(
                command: "python3 -c 'import os,time; os.setsid(); open(\"\(pidFile.path)\",\"w\").write(str(os.getpid())); time.sleep(30)' & wait",
                timeout: .milliseconds(500)
            )
        )

        XCTAssertNotEqual(result.termination, .exited)
        XCTAssertTrue(result.cleanupVerified)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path))
    }

    private func waitUntilGone(_ pid: pid_t) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if processGoneOrZombie(pid) { return true }
            usleep(10_000)
        }
        return processGoneOrZombie(pid)
    }

    private func processGoneOrZombie(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == -1 { return errno == ESRCH }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        return size <= 0 || info.pbi_status == UInt32(SZOMB)
    }

    private func fixture(command: String, timeout: Duration) -> OwnedProcessRequest {
        OwnedProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            standardInput: Data(),
            timeout: timeout
        )
    }
}
