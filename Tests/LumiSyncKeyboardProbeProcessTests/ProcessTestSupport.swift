import Darwin
import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

struct ProcessResult {
    let termination: OwnedProcessTermination
    let stdout: Data
    let stderr: Data
}

enum OwnedScenarioRole {
    case controller
    case writer
}

final class ProcessHarness {
    private let directory: URL
    private let controllerURL: URL
    private let supervisorURL: URL
    private let writerURL: URL

    init(
        initialValue: Double = 0.37,
        pausedAt stage: BacklightStage? = nil
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiSyncProcessTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        self.directory = directory
        controllerURL = try Self.executable(named: "lumisync-backlight-controller")
        supervisorURL = try Self.executable(named: "lumisync-backlight-supervisor")
        writerURL = try Self.executable(named: "lumisync-backlight-writer")
        try FileBackedFakeBacklightDevice.create(
            directory: directory,
            configuration: FakeBacklightDeviceConfiguration(
                initialValue: try NormalizedBacklightValue(initialValue)
            )
        )
        if let stage {
            let encodedFault = try JSONSerialization.data(
                withJSONObject: [["hang": ["stage": stage.rawValue]]]
            )
            try encodedFault.write(
                to: directory.appendingPathComponent("faults.json"),
                options: .atomic
            )
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func run(input: Data, timeout: Duration) async -> ProcessResult {
        let result = await BoundedOwnedProcessRunner().run(
            OwnedProcessRequest(
                executableURL: controllerURL,
                standardInput: input,
                timeout: timeout,
                environment: environment
            )
        )
        return ProcessResult(
            termination: result.termination,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    func startScenario(
        input: Data,
        outerTimeout: Duration = .seconds(5)
    ) throws -> ProcessScenario {
        try ProcessScenario(
            controllerURL: controllerURL,
            input: input,
            environment: environment,
            deviceDirectory: directory,
            outerTimeout: outerTimeout
        )
    }

    func currentValue() throws -> NormalizedBacklightValue {
        try FileBackedFakeBacklightDevice(directory: directory).read(
            requestID: try BacklightRequestID(rawValue: "harness-read")
        )
    }

    func makeRequest(
        requestID: String,
        operation: BacklightOperation,
        deadlineNanoseconds: UInt64 = 2_000_000_000
    ) throws -> BacklightRequest {
        BacklightRequest(
            requestID: try BacklightRequestID(rawValue: requestID),
            operation: operation,
            deadline: try BacklightDeadline(
                remainingNanoseconds: deadlineNanoseconds
            )
        )
    }

    func journalEntries() throws -> [FakeBacklightJournalEntry] {
        try FileBackedFakeBacklightDevice(directory: directory).journalEntries()
    }

    private var environment: [String: String] {
        [
            "LUMISYNC_H1_SUPERVISOR_PATH": supervisorURL.path,
            "LUMISYNC_H1_WRITER_PATH": writerURL.path,
            "LUMISYNC_H1_FAKE_DEVICE_DIR": directory.path
        ]
    }

    private static func executable(named name: String) throws -> URL {
        var base = Bundle(for: ThreeProcessRecoveryTests.self).bundleURL
        for _ in 0..<5 {
            let candidate = base.deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            base = base.deletingLastPathComponent()
        }
        throw NSError(
            domain: "LumiSyncKeyboardProbeProcessTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Unable to locate SwiftPM product \(name)"
            ]
        )
    }
}

final class ProcessScenario {
    private struct ProcessIdentity: Equatable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private let process: Process
    private let stdoutPipe: Pipe
    private let stderrPipe: Pipe
    private let deviceDirectory: URL
    private let deadline: ContinuousClock.Instant
    private var ownedProcesses: [pid_t: ProcessIdentity]
    private var supervisorPID: pid_t?

    init(
        controllerURL: URL,
        input: Data,
        environment: [String: String],
        deviceDirectory: URL,
        outerTimeout: Duration
    ) throws {
        process = Process()
        stdoutPipe = Pipe()
        stderrPipe = Pipe()
        self.deviceDirectory = deviceDirectory
        deadline = ContinuousClock.now.advanced(by: outerTimeout)
        ownedProcesses = [:]

        process.executableURL = controllerURL
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        try process.run()
        guard let controllerIdentity = Self.processIdentity(of: process.processIdentifier) else {
            throw NSError(
                domain: "LumiSyncKeyboardProbeProcessTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unable to record controller identity"]
            )
        }
        ownedProcesses[process.processIdentifier] = controllerIdentity
        try inputPipe.fileHandleForWriting.write(contentsOf: input)
        try inputPipe.fileHandleForWriting.close()
    }

    @discardableResult
    func waitForJournalEvent(
        _ predicate: (FakeBacklightJournalEntry) -> Bool
    ) throws -> FakeBacklightJournalEntry {
        while ContinuousClock.now < deadline {
            let entries = try journalEntries()
            recordOwnedProcesses(from: entries)
            if let entry = entries.first(where: predicate) {
                try recordAncestry(of: entry.processID)
                return entry
            }
            usleep(5_000)
        }
        throw scenarioError("Timed out waiting for journal event")
    }

    func signalOwnedRole(_ role: OwnedScenarioRole, _ signal: Int32) throws {
        let pid: pid_t
        switch role {
        case .controller:
            pid = process.processIdentifier
        case .writer:
            let entries = try journalEntries()
            recordOwnedProcesses(from: entries)
            guard let writerPID = entries.last(where: { $0.processRole == .writer })?.processID else {
                throw scenarioError("No owned writer PID was journaled")
            }
            try recordAncestry(of: writerPID)
            pid = writerPID
        }
        guard let identity = ownedProcesses[pid],
              !Self.processIsGoneOrReused(identity) else {
            throw scenarioError("Refusing to signal unowned PID \(pid)")
        }
        guard kill(pid, signal) == 0 else {
            throw scenarioError("Unable to signal PID \(pid): errno=\(errno)")
        }
    }

    func finish() throws -> ProcessResult {
        while process.isRunning, ContinuousClock.now < deadline {
            usleep(5_000)
        }
        guard !process.isRunning else {
            process.terminate()
            usleep(100_000)
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw scenarioError("Scenario exceeded its outer timeout")
        }
        process.waitUntilExit()
        try waitForOwnedProcessesToExit()

        let termination: OwnedProcessTermination
        switch process.terminationReason {
        case .exit:
            termination = .exited
        case .uncaughtSignal:
            termination = .signaled(process.terminationStatus)
        @unknown default:
            termination = .failed("unknown Process termination reason")
        }
        return ProcessResult(
            termination: termination,
            stdout: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderrPipe.fileHandleForReading.readDataToEndOfFile()
        )
    }

    func currentValue() throws -> NormalizedBacklightValue {
        try FileBackedFakeBacklightDevice(directory: deviceDirectory).read(
            requestID: try BacklightRequestID(rawValue: "scenario-read")
        )
    }

    func journalEntries() throws -> [FakeBacklightJournalEntry] {
        try FileBackedFakeBacklightDevice(directory: deviceDirectory).journalEntries()
    }

    func assertNoOwnedProcessesRemain() throws {
        recordOwnedProcesses(from: try journalEntries())
        let live = ownedProcesses.values.filter { !Self.processIsGoneOrReused($0) }
        guard live.isEmpty else {
            let details = live.map(\.pid).sorted().map { pid in
                let role: String
                if pid == process.processIdentifier {
                    role = "controller"
                } else if pid == supervisorPID {
                    role = "supervisor"
                } else {
                    role = "writer"
                }
                return "\(pid)(\(role),ppid=\(Self.parentPID(of: pid) ?? -1),path=\(Self.processPath(of: pid)))"
            }
            throw scenarioError("Owned processes remain: \(details)")
        }
    }

    private func waitForOwnedProcessesToExit() throws {
        while ContinuousClock.now < deadline {
            recordOwnedProcesses(from: try journalEntries())
            if ownedProcesses.values.allSatisfy(Self.processIsGoneOrReused) {
                return
            }
            usleep(5_000)
        }
        try assertNoOwnedProcessesRemain()
    }

    private func recordOwnedProcesses(from entries: [FakeBacklightJournalEntry]) {
        for pid in entries.lazy
            .filter({ $0.processRole == .writer })
            .map(\.processID)
            where ownedProcesses[pid] == nil {
            if let identity = Self.processIdentity(of: pid) {
                ownedProcesses[pid] = identity
            }
        }
    }

    private func recordAncestry(of writerPID: pid_t) throws {
        guard let parent = Self.parentPID(of: writerPID), parent > 0 else {
            throw scenarioError("Unable to determine writer parent")
        }
        supervisorPID = parent
        if ownedProcesses[parent] == nil,
           let identity = Self.processIdentity(of: parent) {
            ownedProcesses[parent] = identity
        }
        guard let controller = Self.parentPID(of: parent),
              controller == process.processIdentifier else {
            throw scenarioError("Writer PID is outside the scenario controller ancestry")
        }
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func processPath(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return "unavailable" }
        let bytes = buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    private static func processIdentity(of pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return ProcessIdentity(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    private static func processIsGoneOrReused(_ identity: ProcessIdentity) -> Bool {
        if kill(identity.pid, 0) == -1 { return errno == ESRCH }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            identity.pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard size == MemoryLayout<proc_bsdinfo>.size else { return true }
        if info.pbi_start_tvsec != identity.startSeconds
            || info.pbi_start_tvusec != identity.startMicroseconds {
            return true
        }
        return info.pbi_status == UInt32(SZOMB)
    }

    private func scenarioError(_ description: String) -> NSError {
        NSError(
            domain: "LumiSyncKeyboardProbeProcessTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}
