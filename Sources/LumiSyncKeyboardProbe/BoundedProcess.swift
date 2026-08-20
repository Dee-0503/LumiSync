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

internal struct OwnedProcessIdentity: Hashable, Sendable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

internal enum ObservedOwnedProcess: Equatable, Sendable {
    case missing
    case running(OwnedProcessIdentity)
    case zombie(OwnedProcessIdentity)
    case unavailable
}

internal enum ChildPIDSnapshot: Equatable, Sendable {
    case complete([pid_t])
    case incomplete([pid_t])
    case unavailable
}

internal struct DescendantProcessOperations: @unchecked Sendable {
    let observe: (pid_t) -> ObservedOwnedProcess
    let signal: (pid_t, Int32) -> Void
    let children: (pid_t) -> ChildPIDSnapshot
    let groupIsGone: (pid_t) -> Bool
}

internal final class DescendantProcessTracker: @unchecked Sendable {
    private let operations: DescendantProcessOperations
    private var knownDescendants: Set<OwnedProcessIdentity> = []
    private var unresolvedDescendantPIDs: Set<pid_t> = []
    private var discoveryIncomplete = false

    init(operations: DescendantProcessOperations) {
        self.operations = operations
    }

    func track(_ identity: OwnedProcessIdentity) {
        knownDescendants.insert(identity)
    }

    func refreshDescendants(of rootPID: pid_t) {
        var discovered = Set<pid_t>()
        var frontier = [rootPID]
        while let parent = frontier.popLast() {
            let snapshot = operations.children(parent)
            let children: [pid_t]
            switch snapshot {
            case .complete(let values):
                children = values
            case .incomplete(let values):
                discoveryIncomplete = true
                children = values
            case .unavailable:
                discoveryIncomplete = true
                children = []
            }
            for child in children where child > 0 && discovered.insert(child).inserted {
                frontier.append(child)
                switch operations.observe(child) {
                case .running(let identity), .zombie(let identity):
                    unresolvedDescendantPIDs.remove(child)
                    track(identity)
                case .missing:
                    unresolvedDescendantPIDs.remove(child)
                case .unavailable:
                    unresolvedDescendantPIDs.insert(child)
                }
            }
        }
    }

    func signalKnownDescendants(_ signal: Int32) {
        for identity in knownDescendants where identity.pid > 0 {
            guard case .running(let current) = operations.observe(identity.pid),
                  current == identity else {
                continue
            }
            operations.signal(identity.pid, signal)
        }
    }

    func cleanupIsVerified(groupIsGone: Bool) -> Bool {
        guard groupIsGone, !discoveryIncomplete else { return false }
        var resolvedIdentities: [OwnedProcessIdentity] = []
        unresolvedDescendantPIDs = unresolvedDescendantPIDs.filter { pid in
            switch operations.observe(pid) {
            case .missing, .zombie:
                return false
            case .running(let identity):
                resolvedIdentities.append(identity)
                return false
            case .unavailable:
                return true
            }
        }
        resolvedIdentities.forEach(track)
        guard unresolvedDescendantPIDs.isEmpty else { return false }
        return knownDescendants.allSatisfy { identity in
            switch operations.observe(identity.pid) {
            case .missing:
                return true
            case .zombie:
                return true
            case .running(let current):
                return current != identity
            case .unavailable:
                return false
            }
        }
    }
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
                let result = waitpid(process.pid, &waitStatus, WNOHANG | WUNTRACED)
                if result == process.pid {
                    if Self.isStopped(waitStatus) {
                        process.refreshDescendants()
                        _ = kill(process.pid, SIGCONT)
                        continue
                    }
                    didReap = true
                    termination = Self.termination(for: waitStatus)
                    process.refreshDescendants()
                    process.terminateKnownDescendants()
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
                if process.outputLimitWasExceeded() {
                    termination = .failed("output limit exceeded")
                }
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
        } catch let error as SpawnedProcessError {
            return OwnedProcessResult(
                termination: .failed(error.description),
                exitStatus: nil,
                stdout: Data(),
                stderr: Data(),
                rootPID: error.spawnedPID,
                cleanupVerified: error.cleanupVerified
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

    private static func isStopped(_ status: Int32) -> Bool {
        status & 0x7f == 0x7f && (status >> 8) & 0xff != SIGCONT
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

}

private enum SpawnedProcessError: Error, CustomStringConvertible {
    case spawn(Int32)
    case pipe(Int32)
    case standardInput(String, pid_t, Bool)

    var description: String {
        switch self {
        case .spawn(let code): return "posix_spawn failed with errno \(code)"
        case .pipe(let code): return "pipe failed with errno \(code)"
        case .standardInput(let message, _, _): return message
        }
    }

    var spawnedPID: pid_t? {
        guard case .standardInput(_, let pid, _) = self else { return nil }
        return pid
    }

    var cleanupVerified: Bool {
        guard case .standardInput(_, _, let verified) = self else { return true }
        return verified
    }
}

private final class SpawnedProcess: @unchecked Sendable {
    let pid: pid_t
    let groupID: pid_t
    private static let maximumOutputBytes = BoundedOwnedProcessRunner.maximumOutputBytes

    private let input: FileHandle
    private let output: FileHandle
    private let error: FileHandle
    private let outputLock = NSLock()
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var outputLimitExceeded = false
    private let descendantTracker: DescendantProcessTracker

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
        if inputPipe[0] != STDIN_FILENO {
            posix_spawn_file_actions_addclose(&actions, inputPipe[0])
        }
        if outputPipe[1] != STDOUT_FILENO {
            posix_spawn_file_actions_addclose(&actions, outputPipe[1])
        }
        if errorPipe[1] != STDERR_FILENO {
            posix_spawn_file_actions_addclose(&actions, errorPipe[1])
        }

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
        descendantTracker = DescendantProcessTracker(operations: Self.descendantOperations)
        input = FileHandle(fileDescriptor: inputPipe[1], closeOnDealloc: true)
        output = FileHandle(fileDescriptor: outputPipe[0], closeOnDealloc: true)
        error = FileHandle(fileDescriptor: errorPipe[0], closeOnDealloc: true)
        output.readabilityHandler = { [weak self] handle in
            self?.consumeAvailableData(from: handle, isStdout: true)
        }
        error.readabilityHandler = { [weak self] handle in
            self?.consumeAvailableData(from: handle, isStdout: false)
        }
        do {
            try Self.writeStandardInput(request.standardInput, to: input.fileDescriptor)
            closeInput()
        } catch {
            closeInput()
            Self.terminateProcessGroup(groupID)
            terminateKnownDescendants()
            let didReap = Self.reap(pid)
            closeOutput()
            let cleanupVerified = didReap && cleanupVerified()
            throw SpawnedProcessError.standardInput(
                String(describing: error),
                pid,
                cleanupVerified
            )
        }
    }

    private static func writeStandardInput(_ data: Data, to descriptor: Int32) throws {
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written == -1 && errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func terminateProcessGroup(_ groupID: pid_t) {
        guard groupID > 0 else { return }
        _ = kill(-groupID, SIGKILL)
    }

    private static func reap(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { return true }
            if result == -1 && errno == EINTR { continue }
            return result == -1 && errno == ECHILD
        }
    }

    func closeInput() {
        try? input.close()
    }

    func closeOutput() {
        output.readabilityHandler = nil
        error.readabilityHandler = nil
        try? output.close()
        try? error.close()
    }

    func cleanupVerified() -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if descendantTracker.cleanupIsVerified(
                groupIsGone: Self.descendantOperations.groupIsGone(groupID)
            ) {
                return true
            }
            descendantTracker.signalKnownDescendants(SIGKILL)
            usleep(5_000)
        }
        return descendantTracker.cleanupIsVerified(
            groupIsGone: Self.descendantOperations.groupIsGone(groupID)
        )
    }

    func terminateKnownDescendants() {
        refreshDescendants()
        descendantTracker.signalKnownDescendants(SIGTERM)
        descendantTracker.signalKnownDescendants(SIGKILL)
    }

    func refreshDescendants() {
        descendantTracker.refreshDescendants(of: pid)
    }

    private static let descendantOperations = DescendantProcessOperations(
        observe: { pid in
            if kill(pid, 0) == -1 {
                return errno == ESRCH ? .missing : .unavailable
            }
            var info = proc_bsdinfo()
            let size = proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                &info,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            guard size == MemoryLayout<proc_bsdinfo>.size else { return .unavailable }
            let identity = OwnedProcessIdentity(
                pid: pid,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            )
            return info.pbi_status == UInt32(SZOMB)
                ? .zombie(identity)
                : .running(identity)
        },
        signal: { pid, signal in
            _ = kill(pid, signal)
        },
        children: { pid in
            descendantPIDs(of: pid)
        },
        groupIsGone: { groupID in
            guard groupID > 0 else { return true }
            if kill(-groupID, 0) == 0 { return false }
            return errno == ESRCH
        }
    )

    private static let maximumChildPIDCount = 4_096

    private static func descendantPIDs(of parent: pid_t) -> ChildPIDSnapshot {
        var capacity = 32
        while capacity <= maximumChildPIDCount {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let returnedCount = buffer.withUnsafeMutableBufferPointer {
                proc_listchildpids(
                    parent,
                    $0.baseAddress,
                    Int32($0.count * MemoryLayout<pid_t>.stride)
                )
            }
            guard returnedCount >= 0 else { return .unavailable }
            let count = min(Int(returnedCount), buffer.count)
            let children = Array(buffer.prefix(count)).filter { $0 > 0 }
            guard Int(returnedCount) < buffer.count else {
                guard capacity < maximumChildPIDCount else {
                    return .incomplete(children)
                }
                capacity = min(capacity * 2, maximumChildPIDCount)
                continue
            }
            return .complete(children)
        }
        return .unavailable
    }

    func collectOutput() async -> (stdout: Data, stderr: Data) {
        collectOutputSynchronously()
    }

    private func collectOutputSynchronously() -> (stdout: Data, stderr: Data) {
        output.readabilityHandler = nil
        error.readabilityHandler = nil
        consumeAvailableData(from: output, isStdout: true)
        consumeAvailableData(from: error, isStdout: false)
        outputLock.lock()
        defer { outputLock.unlock() }
        return (stdoutBuffer, stderrBuffer)
    }

    private func consumeAvailableData(from handle: FileHandle, isStdout: Bool) {
        let data = handle.availableData
        guard !data.isEmpty else { return }
        outputLock.lock()
        defer { outputLock.unlock() }
        let remaining = Self.maximumOutputBytes - (isStdout ? stdoutBuffer.count : stderrBuffer.count)
        if data.count > remaining {
            outputLimitExceeded = true
        }
        if isStdout {
            Self.appendBounded(data, to: &stdoutBuffer)
        } else {
            Self.appendBounded(data, to: &stderrBuffer)
        }
    }

    func outputLimitWasExceeded() -> Bool {
        outputLock.lock()
        defer { outputLock.unlock() }
        return outputLimitExceeded
    }

    private static func appendBounded(_ data: Data, to buffer: inout Data) {
        let remaining = maximumOutputBytes - buffer.count
        guard remaining > 0 else { return }
        buffer.append(data.prefix(remaining))
    }
}
