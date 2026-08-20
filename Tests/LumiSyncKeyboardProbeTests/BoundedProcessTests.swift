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

    func testRunnerPreservesChildStandardIOWhenParentDescriptorsAreClosed() async throws {
        let backups = [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO].map {
            fcntl($0, F_DUPFD_CLOEXEC, 10)
        }
        XCTAssertTrue(backups.allSatisfy { $0 >= 10 })
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            XCTAssertEqual(close(descriptor), 0)
        }

        let result = await runner.run(
            fixture(command: "read value; printf 'out:%s' \"$value\"; printf err >&2", standardInput: Data("ok\n".utf8), timeout: .seconds(1))
        )

        for (descriptor, backup) in zip([STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO], backups) {
            XCTAssertEqual(dup2(backup, descriptor), descriptor)
            _ = close(backup)
        }
        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "out:ok")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "err")
        XCTAssertTrue(result.cleanupVerified)
    }

    func testRunnerDrainsStdoutAndStderrConcurrently() async {
        let result = await runner.run(
            fixture(
                command: "python3 -c 'import os; os.write(2, b\"e\" * 1048576); os.write(1, b\"o\" * 1048576)'",
                timeout: .seconds(2)
            )
        )

        XCTAssertEqual(result.termination, .failed("output limit exceeded"))
        XCTAssertNil(result.exitStatus)
        XCTAssertEqual(result.stdout.count, 65_536)
        XCTAssertEqual(result.stderr.count, 65_536)
        XCTAssertTrue(result.cleanupVerified)
    }

    func testRunnerMarksTruncatedOutputAsProtocolFailure() async {
        let result = await runner.run(
            fixture(
                command: "python3 -c 'import os; os.write(1, b\"o\" * 65537)'",
                timeout: .seconds(2)
            )
        )

        XCTAssertEqual(result.termination, .failed("output limit exceeded"))
        XCTAssertEqual(result.stdout.count, 65_536)
        XCTAssertTrue(result.cleanupVerified)
    }

    func testRunnerCleansUpSpawnedProcessWhenWritingStandardInputFails() async throws {
        let result = await runner.run(
            fixture(
                command: "exec 0<&-; sleep 30",
                standardInput: Data(repeating: 0x61, count: 1_048_576),
                timeout: .seconds(2)
            )
        )

        XCTAssertNotEqual(result.termination, .exited)
        let pid = try XCTUnwrap(result.rootPID)
        XCTAssertTrue(result.cleanupVerified)
        XCTAssertTrue(waitUntilGone(pid))
    }

    func testRunnerTimesOutWhileStandardInputIsBackpressured() async throws {
        let started = ContinuousClock.now

        let result = await runner.run(
            fixture(
                command: "sleep 2",
                standardInput: Data(repeating: 0x61, count: 4 * 1_024 * 1_024),
                timeout: .milliseconds(150)
            )
        )

        let elapsed = started.duration(to: .now)
        XCTAssertEqual(result.termination, .timedOut)
        XCTAssertNil(result.exitStatus)
        XCTAssertTrue(result.cleanupVerified)
        let pid = try XCTUnwrap(result.rootPID)
        XCTAssertTrue(waitUntilGone(pid))
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testCancellingRunnerTerminatesAndReapsOwnedProcess() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumisync-cancelled-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let request = fixture(
            command: "printf '%s' $$ > \(pidFile.path); sleep 30",
            timeout: .seconds(10)
        )
        let ownedRunner = BoundedOwnedProcessRunner()
        let task = Task {
            await ownedRunner.run(request)
        }
        let pid = try XCTUnwrap(waitForPID(in: pidFile))
        let started = ContinuousClock.now

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.termination, .failed("cancelled"))
        XCTAssertNil(result.exitStatus)
        XCTAssertTrue(result.cleanupVerified)
        XCTAssertTrue(waitUntilGone(pid))
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testCancellingRunnerWhileStandardInputIsBackpressuredReapsOwnedProcess() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumisync-cancelled-input-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let request = fixture(
            command: "printf '%s' $$ > \(pidFile.path); sleep 30",
            standardInput: Data(repeating: 0x61, count: 4 * 1_024 * 1_024),
            timeout: .seconds(2)
        )
        let ownedRunner = BoundedOwnedProcessRunner()
        let task = Task {
            await ownedRunner.run(request)
        }
        let pid = try XCTUnwrap(waitForPID(in: pidFile))
        let started = ContinuousClock.now

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.termination, .failed("cancelled"))
        XCTAssertNil(result.exitStatus)
        XCTAssertTrue(result.cleanupVerified)
        XCTAssertTrue(waitUntilGone(pid))
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testCancellingRunnerWhileCollectingOutputReturnsPromptly() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumisync-cancelled-output-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let command = "python3 -c 'import os,time; os.setsid(); pid=os.fork(); pid and os._exit(0); time.sleep(0.1); open(\"\(pidFile.path)\",\"w\").write(str(os.getpid())); time.sleep(30)' & exit 0"
        let request = fixture(command: command, timeout: .seconds(2))
        let ownedRunner = BoundedOwnedProcessRunner()
        let task = Task {
            await ownedRunner.run(request)
        }
        let escapedPID = try XCTUnwrap(waitForPID(in: pidFile))
        defer {
            _ = kill(escapedPID, SIGKILL)
            _ = waitUntilGone(escapedPID)
        }
        usleep(50_000)
        let started = ContinuousClock.now

        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.termination, .failed("cancelled"))
        XCTAssertNil(result.exitStatus)
        XCTAssertFalse(result.cleanupVerified)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testRunnerFailsClosedBeforeSpawnWhenSIGCHLDIsIgnored() async {
        let previousCHLD = Darwin.signal(SIGCHLD, SIG_IGN)
        defer { _ = Darwin.signal(SIGCHLD, previousCHLD) }
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumisync-sigchld-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let result = await runner.run(
            fixture(
                command: "printf '%s' $$ > \(pidFile.path)",
                timeout: .seconds(1)
            )
        )

        XCTAssertEqual(
            result.termination,
            .failed("SIGCHLD disposition prevents owned child reaping")
        )
        XCTAssertNil(result.exitStatus)
        XCTAssertNil(result.rootPID)
        XCTAssertFalse(result.cleanupVerified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path))
    }

    func testRunnerLeavesIgnoredSIGCHLDDispositionUnchanged() async {
        let previousCHLD = Darwin.signal(SIGCHLD, SIG_IGN)
        defer { _ = Darwin.signal(SIGCHLD, previousCHLD) }

        _ = await runner.run(
            fixture(command: "exit 0", timeout: .seconds(1))
        )

        let unchangedCHLD = Darwin.signal(SIGCHLD, SIG_IGN)
        XCTAssertEqual(
            unsafeBitCast(unchangedCHLD, to: UnsafeRawPointer?.self),
            unsafeBitCast(SIG_IGN, to: UnsafeRawPointer?.self)
        )
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

    func testRunnerFailsClosedForReparentedDoubleForkAfterStandardIOCloses() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumisync-double-fork-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
        import os,time
        if os.fork() == 0:
            os.setsid()
            if os.fork() > 0:
                os._exit(0)
            os.close(0); os.close(1); os.close(2)
            open(\"\(pidFile.path)\", \"w\").write(str(os.getpid()))
            time.sleep(30)
        while not os.path.exists(\"\(pidFile.path)\"):
            time.sleep(0.001)
        """

        let result = await runner.run(
            OwnedProcessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                arguments: ["-c", script],
                timeout: .seconds(1),
                descendantPolicy: .unverified
            )
        )

        let escapedPID = try XCTUnwrap(waitForPID(in: pidFile))
        defer {
            _ = kill(escapedPID, SIGKILL)
            _ = waitUntilGone(escapedPID)
        }
        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertFalse(result.cleanupVerified)
    }

    func testRunnerFailsClosedWhenUnscannedSetsidDescendantKeepsOutputPipesOpen() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumisync-output-escape-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let command = "python3 -c 'import os,time; os.setsid(); pid=os.fork(); pid and os._exit(0); open(\"\(pidFile.path)\",\"w\").write(str(os.getpid())); time.sleep(30)' & while [ ! -s \(pidFile.path) ]; do sleep 0.01; done; exit 0"
        let started = ContinuousClock.now

        let result = await runner.run(
            fixture(command: command, timeout: .milliseconds(250))
        )

        let elapsed = started.duration(to: .now)
        let escapedPID = try XCTUnwrap(
            Int32(try String(contentsOf: pidFile, encoding: .utf8))
        )
        defer {
            _ = kill(escapedPID, SIGKILL)
            _ = waitUntilGone(escapedPID)
        }
        XCTAssertEqual(
            result.termination,
            .failed("output did not reach EOF before deadline")
        )
        XCTAssertNil(result.exitStatus)
        XCTAssertFalse(result.cleanupVerified)
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testDescendantCleanupDoesNotSignalPIDWhenIdentityCheckDetectsReuse() {
        let owned = OwnedProcessIdentity(pid: 4_242, startSeconds: 10, startMicroseconds: 1)
        let replacement = OwnedProcessIdentity(pid: 4_242, startSeconds: 20, startMicroseconds: 2)
        var signals: [(pid_t, Int32)] = []
        let tracker = DescendantProcessTracker(
            operations: DescendantProcessOperations(
                observe: { _ in .running(replacement) },
                signal: { signals.append(($0, $1)) },
                children: { _ in .complete([]) },
                groupIsGone: { _ in true }
            )
        )
        tracker.track(owned)

        tracker.signalKnownDescendants(SIGKILL)

        XCTAssertTrue(signals.isEmpty)
        XCTAssertTrue(tracker.cleanupIsVerified(groupIsGone: true))
    }

    func testDescendantCleanupFailsClosedWhenIdentityIsUnavailable() {
        let owned = OwnedProcessIdentity(pid: 4_242, startSeconds: 10, startMicroseconds: 1)
        var signals: [(pid_t, Int32)] = []
        let tracker = DescendantProcessTracker(
            operations: DescendantProcessOperations(
                observe: { _ in .unavailable },
                signal: { signals.append(($0, $1)) },
                children: { _ in .complete([]) },
                groupIsGone: { _ in true }
            )
        )
        tracker.track(owned)

        tracker.signalKnownDescendants(SIGTERM)

        XCTAssertTrue(signals.isEmpty)
        XCTAssertFalse(tracker.cleanupIsVerified(groupIsGone: true))
    }

    func testDescendantCleanupSignalsOnlyMatchingLiveIdentity() {
        let owned = OwnedProcessIdentity(pid: 4_242, startSeconds: 10, startMicroseconds: 1)
        var signals: [(pid_t, Int32)] = []
        let tracker = DescendantProcessTracker(
            operations: DescendantProcessOperations(
                observe: { _ in .running(owned) },
                signal: { signals.append(($0, $1)) },
                children: { _ in .complete([]) },
                groupIsGone: { _ in true }
            )
        )
        tracker.track(owned)

        tracker.signalKnownDescendants(SIGTERM)
        tracker.signalKnownDescendants(SIGKILL)

        XCTAssertEqual(signals.map(\.0), [4_242, 4_242])
        XCTAssertEqual(signals.map(\.1), [SIGTERM, SIGKILL])
        XCTAssertFalse(tracker.cleanupIsVerified(groupIsGone: true))
    }

    func testIncompleteDescendantDiscoveryFailsCleanupClosed() {
        let tracker = DescendantProcessTracker(
            operations: DescendantProcessOperations(
                observe: { _ in .unavailable },
                signal: { _, _ in },
                children: { _ in .incomplete([]) },
                groupIsGone: { _ in true }
            )
        )

        tracker.refreshDescendants(of: 1_234)

        XCTAssertFalse(tracker.cleanupIsVerified(groupIsGone: true))
    }

    func testDiscoveredChildWithUnavailableIdentityFailsCleanupClosed() {
        let childPID: pid_t = 4_242
        let tracker = DescendantProcessTracker(
            operations: DescendantProcessOperations(
                observe: { _ in .unavailable },
                signal: { _, _ in },
                children: { parent in
                    parent == 1_234 ? .complete([childPID]) : .complete([])
                },
                groupIsGone: { _ in true }
            )
        )

        tracker.refreshDescendants(of: 1_234)

        XCTAssertFalse(tracker.cleanupIsVerified(groupIsGone: true))
    }

    func testUnavailableDescendantDiscoveryFailsCleanupClosed() {
        let tracker = DescendantProcessTracker(
            operations: DescendantProcessOperations(
                observe: { _ in .unavailable },
                signal: { _, _ in },
                children: { _ in .unavailable },
                groupIsGone: { _ in true }
            )
        )

        tracker.refreshDescendants(of: 1_234)

        XCTAssertFalse(tracker.cleanupIsVerified(groupIsGone: true))
    }

    private func waitForPID(in url: URL) -> pid_t? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(contents) {
                return pid
            }
            usleep(5_000)
        }
        return nil
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

    private func fixture(
        command: String,
        standardInput: Data = Data(),
        timeout: Duration,
        descendantPolicy: OwnedProcessDescendantPolicy = .executableContractNoDescendants
    ) -> OwnedProcessRequest {
        OwnedProcessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            standardInput: standardInput,
            timeout: timeout,
            descendantPolicy: descendantPolicy
        )
    }
}
