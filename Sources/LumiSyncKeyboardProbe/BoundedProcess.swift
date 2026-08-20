import Darwin
import Foundation

public enum OwnedProcessTermination: Equatable, Sendable {
    case exited
    case signaled(Int32)
    case timedOut
    case failed(String)
}

public struct OwnedProcessRequest: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let standardInput: Data
    public let timeout: Duration
    public let environment: [String: String]?

    public init(
        executableURL: URL,
        arguments: [String] = [],
        standardInput: Data = Data(),
        timeout: Duration,
        environment: [String: String]? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        self.timeout = timeout
        self.environment = environment
    }
}

public struct OwnedProcessResult: Equatable, Sendable {
    public let termination: OwnedProcessTermination
    public let exitStatus: Int32?
    public let stdout: Data
    public let stderr: Data
    public let rootPID: Int32?
    public let cleanupVerified: Bool

    public init(
        termination: OwnedProcessTermination,
        exitStatus: Int32?,
        stdout: Data,
        stderr: Data,
        rootPID: Int32?,
        cleanupVerified: Bool
    ) {
        self.termination = termination
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.rootPID = rootPID
        self.cleanupVerified = cleanupVerified
    }
}

public protocol OwnedProcessRunning: Sendable {
    func run(_ request: OwnedProcessRequest) async -> OwnedProcessResult
}

public actor BoundedOwnedProcessRunner: OwnedProcessRunning {
    fileprivate static let maximumOutputBytes = 64 * 1024
    private static let terminationGraceNanoseconds: UInt64 = 100_000_000
    private static let pollNanoseconds: UInt64 = 5_000_000

    public init() {}

    public func run(_ request: OwnedProcessRequest) async -> OwnedProcessResult {
        do {
            let process = try SpawnedProcess(request: request)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: request.timeout)
            var waitStatus: Int32 = 0
            var termination: OwnedProcessTermination = .exited
            var didReap = false

            while true {
                let result = waitpid(process.pid, &waitStatus, WNOHANG)
                if result == process.pid {
                    didReap = true
                    termination = Self.termination(for: waitStatus)
                    break
                }
                if result == -1 {
                    if errno == EINTR { continue }
                    termination = .failed(String(cString: strerror(errno)))
                    break
                }
                process.refreshDescendants()
                if clock.now >= deadline {
                    termination = .timedOut
                    process.refreshDescendants()
                    Self.terminateProcessGroup(process.groupID)
                    process.terminateKnownDescendants()
                    let graceDeadline = clock.now.advanced(by: .nanoseconds(Self.terminationGraceNanoseconds))
                    while clock.now < graceDeadline {
                        let graceResult = waitpid(process.pid, &waitStatus, WNOHANG)
                        if graceResult == process.pid {
                            didReap = true
                            break
                        }
                        if graceResult == -1 && errno != EINTR { break }
                        try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
                    }
                    if !didReap {
                        Self.killProcessGroup(process.groupID)
                        while waitpid(process.pid, &waitStatus, 0) == -1 && errno == EINTR {}
                        didReap = true
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
            }

            process.closeInput()
            let output: (stdout: Data, stderr: Data)
            if termination == .timedOut {
                process.closeOutput()
                output = (Data(), Data())
            } else {
                output = await process.collectOutput()
            }
            let cleanupVerified = didReap && process.cleanupVerified()
            return OwnedProcessResult(
                termination: termination,
                exitStatus: termination == .exited ? Self.exitStatus(for: waitStatus) : nil,
                stdout: output.stdout,
                stderr: output.stderr,
                rootPID: process.pid,
                cleanupVerified: cleanupVerified
            )
        } catch {
            return OwnedProcessResult(
                termination: .failed(String(describing: error)),
                exitStatus: nil,
                stdout: Data(),
                stderr: Data(),
                rootPID: nil,
                cleanupVerified: true
            )
        }
    }

    private static func termination(for status: Int32) -> OwnedProcessTermination {
        if status & 0x7f == 0 { return .exited }
        return .signaled(status & 0x7f)
    }

    private static func exitStatus(for status: Int32) -> Int32 {
        (status >> 8) & 0xff
    }

    private static func terminateProcessGroup(_ groupID: pid_t) {
        guard groupID > 0 else { return }
        _ = kill(-groupID, SIGTERM)
    }

    private static func killProcessGroup(_ groupID: pid_t) {
        guard groupID > 0 else { return }
        _ = kill(-groupID, SIGKILL)
    }

    private static func groupIsGone(_ groupID: pid_t) -> Bool {
        guard groupID > 0 else { return true }
        if kill(-groupID, 0) == 0 { return false }
        return errno == ESRCH
    }
}

private enum SpawnedProcessError: Error, CustomStringConvertible {
    case spawn(Int32)
    case pipe(Int32)

    var description: String {
        switch self {
        case .spawn(let code): return "posix_spawn failed with errno \(code)"
        case .pipe(let code): return "pipe failed with errno \(code)"
        }
    }
}

private final class SpawnedProcess: @unchecked Sendable {
    let pid: pid_t
    let groupID: pid_t
    private let input: FileHandle
    private let output: FileHandle
    private let error: FileHandle
    private let outputQueue = DispatchQueue(label: "lumisync.bounded-process.output")
    private var knownDescendantPIDs: Set<pid_t> = []

    init(request: OwnedProcessRequest) throws {
        var inputPipe = [Int32](repeating: 0, count: 2)
        var outputPipe = [Int32](repeating: 0, count: 2)
        var errorPipe = [Int32](repeating: 0, count: 2)
        guard pipe(&inputPipe) == 0,
              pipe(&outputPipe) == 0,
              pipe(&errorPipe) == 0
        else {
            inputPipe.forEach { _ = close($0) }
            outputPipe.forEach { _ = close($0) }
            errorPipe.forEach { _ = close($0) }
            throw SpawnedProcessError.pipe(errno)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, inputPipe[1])
        posix_spawn_file_actions_addclose(&actions, outputPipe[0])
        posix_spawn_file_actions_addclose(&actions, errorPipe[0])

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        for signal in [SIGINT, SIGTERM, SIGABRT] {
            sigaddset(&defaultSignals, signal)
        }
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        posix_spawnattr_setsigmask(&attributes, &signalMask)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        posix_spawnattr_setpgroup(&attributes, 0)

        var argv = [UnsafeMutablePointer<CChar>?](repeating: nil, count: request.arguments.count + 2)
        let executable = request.executableURL.path
        let strings = [executable] + request.arguments
        for index in strings.indices {
            argv[index] = strdup(strings[index])
        }
        defer {
            for pointer in argv where pointer != nil { free(pointer) }
        }

        let environmentStrings: [String]
        if let environment = request.environment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                merged[key] = value
            }
            environmentStrings = merged.map { "\($0.key)=\($0.value)" }
        } else {
            environmentStrings = []
        }
        var environmentPointers = environmentStrings.map { strdup($0) }
        environmentPointers.append(nil)
        defer {
            for pointer in environmentPointers where pointer != nil { free(pointer) }
        }

        var spawnedPID: pid_t = 0
        let result = executable.withCString { executableCString in
            argv.withUnsafeMutableBufferPointer { argumentBuffer in
                environmentPointers.withUnsafeMutableBufferPointer { environmentBuffer in
                    posix_spawn(
                        &spawnedPID,
                        executableCString,
                        &actions,
                        &attributes,
                        argumentBuffer.baseAddress,
                        request.environment == nil ? environ : environmentBuffer.baseAddress
                    )
                }
            }
        }
        guard result == 0 else {
            inputPipe.forEach { _ = close($0) }
            outputPipe.forEach { _ = close($0) }
            errorPipe.forEach { _ = close($0) }
            throw SpawnedProcessError.spawn(result)
        }

        _ = close(inputPipe[0])
        _ = close(outputPipe[1])
        _ = close(errorPipe[1])
        pid = spawnedPID
        groupID = spawnedPID
        input = FileHandle(fileDescriptor: inputPipe[1], closeOnDealloc: true)
        output = FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: true)
        error = FileHandle(fileDescriptor: errorPipe[0], closeOnDealloc: true)
        try input.write(contentsOf: request.standardInput)
        closeInput()
    }

    func closeInput() {
        try? input.close()
    }

    func closeOutput() {
        try? output.close()
        try? error.close()
    }

    private func processIsGoneOrZombie(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == -1 { return errno == ESRCH }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        return size <= 0 || info.pbi_status == UInt32(SZOMB)
    }

    func cleanupVerified() -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if knownDescendantPIDs.allSatisfy(processIsGoneOrZombie) && groupIsGone() {
                return true
            }
            for childPID in knownDescendantPIDs where childPID > 0 {
                _ = kill(childPID, SIGKILL)
            }
            usleep(5_000)
        }
        return knownDescendantPIDs.allSatisfy(processIsGoneOrZombie) && groupIsGone()
    }

    private func groupIsGone() -> Bool {
        guard groupID > 0 else { return true }
        if kill(-groupID, 0) == 0 { return false }
        return errno == ESRCH
    }

    func terminateKnownDescendants() {
        knownDescendantPIDs.formUnion(Self.descendantPIDs(of: pid))
        for childPID in knownDescendantPIDs where childPID > 0 {
            _ = kill(childPID, SIGTERM)
        }
        for childPID in knownDescendantPIDs where childPID > 0 {
            _ = kill(childPID, SIGKILL)
        }
    }

    func refreshDescendants() {
        knownDescendantPIDs.formUnion(Self.descendantPIDs(of: pid))
    }

    private static func descendantPIDs(of rootPID: pid_t) -> Set<pid_t> {
        var discovered = Set<pid_t>()
        var frontier = [rootPID]
        while let parent = frontier.popLast() {
            var buffer = [pid_t](repeating: 0, count: 32)
            let count = buffer.withUnsafeMutableBufferPointer {
                proc_listchildpids(parent, $0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
            }
            guard count > 0 else { continue }
            let childCount = Int(count) / MemoryLayout<pid_t>.size
            for child in buffer.prefix(childCount) where child > 0 && discovered.insert(child).inserted {
                frontier.append(child)
            }
        }
        return discovered
    }

    func collectOutput() async -> (stdout: Data, stderr: Data) {
        await withTaskGroup(of: (Bool, Data).self, returning: (Data, Data).self) { group in
            group.addTask { [output, outputQueue] in
                (true, Self.readBounded(output, queue: outputQueue))
            }
            group.addTask { [error, outputQueue] in
                (false, Self.readBounded(error, queue: outputQueue))
            }
            var stdout = Data()
            var stderr = Data()
            while let (isStdout, data) = await group.next() {
                if isStdout {
                    stdout = data
                } else {
                    stderr = data
                }
            }
            return (stdout, stderr)
        }
    }

    private static func readBounded(_ handle: FileHandle, queue: DispatchQueue) -> Data {
        queue.sync {
            var result = Data()
            while result.count < BoundedOwnedProcessRunner.maximumOutputBytes {
                let data = handle.readData(ofLength: min(4096, BoundedOwnedProcessRunner.maximumOutputBytes - result.count))
                if data.isEmpty { break }
                result.append(data)
            }
            return result
        }
    }
}
