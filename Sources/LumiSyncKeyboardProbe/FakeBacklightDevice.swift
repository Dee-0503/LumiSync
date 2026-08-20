import Darwin
import Foundation

public enum FakeBacklightDeviceError: Error, Equatable, Sendable {
    case invalidDirectory
    case invalidFile(String)
    case oversizedFile(String)
    case invalidState
    case indeterminateTransaction
    case oversizedJournalRecord
    case journalFull
    case systemCall(String, Int32)
}

public enum FakeBacklightFaultAction: Codable, Equatable, Sendable {
    case returnValue(NormalizedBacklightValue)
    case sleepNanoseconds(UInt64)
    case exit(code: Int32)
    case raise(signal: Int32)
    case hang(stage: BacklightStage)
    case malformedOutput
    case forkSleepingChild
    case attemptSetsid
}

public struct FakeBacklightHangBarrier: Codable, Equatable, Sendable {
    public let stage: BacklightStage
    public let requestID: BacklightRequestID
    public let processID: Int32

    public init(stage: BacklightStage, requestID: BacklightRequestID, processID: Int32) {
        self.stage = stage
        self.requestID = requestID
        self.processID = processID
    }
}

public struct FakeBacklightDeviceConfiguration: Codable, Equatable, Sendable {
    public let initialValue: NormalizedBacklightValue
    public let faultActions: [FakeBacklightFaultAction]

    public init(
        initialValue: NormalizedBacklightValue,
        faultActions: [FakeBacklightFaultAction] = []
    ) {
        self.initialValue = initialValue
        self.faultActions = faultActions
    }
}

public enum FakeBacklightProcessRole: String, Codable, Equatable, Sendable {
    case controller
    case supervisor
    case writer
    case test
}

public enum FakeBacklightOperationCategory: String, Codable, Equatable, Sendable {
    case read
    case set
    case restore
}

public enum FakeBacklightJournalPhase: String, Codable, Equatable, Sendable {
    case prepare
    case commit
    case abort
}

public enum FakeBacklightWritePurpose: Equatable, Sendable {
    case journalPrepare
    case journalCommit
    case journalEntry
    case stateFile
    case otherFile
}

public enum FakeBacklightSyncPurpose: Equatable, Sendable {
    case journalPrepare
    case journalCommit
    case journalEntry
    case stateFile
    case stateDirectory
    case otherFile
    case journalTailRepair
}

public protocol FakeBacklightSystemCalling: Sendable {
    func beginWrite(_ purpose: FakeBacklightWritePurpose, descriptor: Int32)
    func endWrite(descriptor: Int32)
    func write(_ descriptor: Int32, buffer: UnsafeRawPointer, count: Int) -> Int
    func fsync(_ descriptor: Int32, purpose: FakeBacklightSyncPurpose) -> Int32
    func rename(_ source: String, _ destination: String) -> Int32
    func ftruncate(_ descriptor: Int32, length: off_t) -> Int32
}

public struct DarwinFakeBacklightSystemCalls: FakeBacklightSystemCalling {
    public init() {}
    public func beginWrite(_ purpose: FakeBacklightWritePurpose, descriptor: Int32) {}
    public func endWrite(descriptor: Int32) {}
    public func write(_ descriptor: Int32, buffer: UnsafeRawPointer, count: Int) -> Int {
        Darwin.write(descriptor, buffer, count)
    }
    public func fsync(_ descriptor: Int32, purpose: FakeBacklightSyncPurpose) -> Int32 {
        Darwin.fsync(descriptor)
    }
    public func rename(_ source: String, _ destination: String) -> Int32 {
        Darwin.rename(source, destination)
    }
    public func ftruncate(_ descriptor: Int32, length: off_t) -> Int32 {
        Darwin.ftruncate(descriptor, length)
    }
}

public struct FakeBacklightJournalEntry: Codable, Equatable, Sendable {
    public let sequenceNumber: UInt64
    public let requestID: BacklightRequestID
    public let processRole: FakeBacklightProcessRole
    public let operationCategory: FakeBacklightOperationCategory
    public let value: NormalizedBacklightValue
    public let processID: Int32
    public let phase: FakeBacklightJournalPhase
    public let previousValue: NormalizedBacklightValue?

    public init(
        sequenceNumber: UInt64,
        requestID: BacklightRequestID,
        processRole: FakeBacklightProcessRole,
        operationCategory: FakeBacklightOperationCategory,
        value: NormalizedBacklightValue,
        processID: Int32,
        phase: FakeBacklightJournalPhase = .commit,
        previousValue: NormalizedBacklightValue? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.requestID = requestID
        self.processRole = processRole
        self.operationCategory = operationCategory
        self.value = value
        self.processID = processID
        self.phase = phase
        self.previousValue = previousValue
    }

    private enum CodingKeys: String, CodingKey {
        case sequenceNumber
        case requestID
        case processRole
        case operationCategory
        case value
        case processID
        case phase
        case previousValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequenceNumber = try container.decode(UInt64.self, forKey: .sequenceNumber)
        requestID = try container.decode(BacklightRequestID.self, forKey: .requestID)
        processRole = try container.decode(FakeBacklightProcessRole.self, forKey: .processRole)
        operationCategory = try container.decode(
            FakeBacklightOperationCategory.self,
            forKey: .operationCategory
        )
        value = try container.decode(NormalizedBacklightValue.self, forKey: .value)
        processID = try container.decode(Int32.self, forKey: .processID)
        phase = try container.decodeIfPresent(
            FakeBacklightJournalPhase.self,
            forKey: .phase
        ) ?? .commit
        previousValue = try container.decodeIfPresent(
            NormalizedBacklightValue.self,
            forKey: .previousValue
        )
    }
}

public final class FileBackedFakeBacklightDevice {
    public static let maximumFaultFileBytes = 16_384
    public static let maximumJournalRecordBytes = 4_096
    public static let maximumJournalBytes = 1_048_576

    private let directory: URL
    private let processRole: FakeBacklightProcessRole
    private let stateURL: URL
    private let faultsURL: URL
    private let journalURL: URL
    private let lockURL: URL
    private let systemCalls: any FakeBacklightSystemCalling

    private func hangBarrierURL(for stage: BacklightStage) -> URL {
        directory.appendingPathComponent("hang-\(stage.rawValue).json")
    }

    public init(
        directory: URL,
        processRole: FakeBacklightProcessRole = .test,
        systemCalls: any FakeBacklightSystemCalling = DarwinFakeBacklightSystemCalls()
    ) throws {
        self.directory = directory.standardizedFileURL
        self.processRole = processRole
        self.systemCalls = systemCalls
        stateURL = self.directory.appendingPathComponent("state.json")
        faultsURL = self.directory.appendingPathComponent("faults.json")
        journalURL = self.directory.appendingPathComponent("journal.jsonl")
        lockURL = self.directory.appendingPathComponent("device.lock")
        try Self.validateDirectory(self.directory)
        try Self.validateExistingFile(stateURL)
        try Self.validateExistingFile(faultsURL)
        try Self.validateExistingFile(journalURL)
        try Self.validateExistingFile(lockURL)
    }

    public static func create(
        directory: URL,
        configuration: FakeBacklightDeviceConfiguration
    ) throws {
        let directory = directory.standardizedFileURL
        try validateDirectory(directory)
        let stateURL = directory.appendingPathComponent("state.json")
        let faultsURL = directory.appendingPathComponent("faults.json")
        let journalURL = directory.appendingPathComponent("journal.jsonl")
        let lockURL = directory.appendingPathComponent("device.lock")

        for url in [stateURL, faultsURL, journalURL, lockURL] {
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw FakeBacklightDeviceError.invalidFile(url.lastPathComponent)
            }
        }

        try writeNewFile(JSONEncoder().encode(configuration.initialValue), to: stateURL)
        let encodedFaults = try JSONEncoder().encode(configuration.faultActions)
        guard encodedFaults.count <= maximumFaultFileBytes else {
            throw FakeBacklightDeviceError.oversizedFile(faultsURL.lastPathComponent)
        }
        try writeNewFile(encodedFaults, to: faultsURL)
        try writeNewFile(Data(), to: journalURL)
        try writeNewFile(Data(), to: lockURL)
    }

    public func read(requestID: BacklightRequestID) throws -> NormalizedBacklightValue {
        try withLock {
            let value = try readStateLocked()
            let records = try recoverJournalLocked(state: value)
            try appendJournalLocked(
                requestID: requestID,
                category: .read,
                value: value,
                processID: getpid(),
                existingRecords: records
            )
            return value
        }
    }

    public func write(
        _ value: NormalizedBacklightValue,
        requestID: BacklightRequestID
    ) throws {
        try write(value, requestID: requestID, operationCategory: .set)
    }

    public func write(
        _ value: NormalizedBacklightValue,
        requestID: BacklightRequestID,
        operationCategory: FakeBacklightOperationCategory
    ) throws {
        try withLock {
            let previousValue = try readStateLocked()
            let records = try recoverJournalLocked(state: previousValue)
            let sequenceNumber = try nextSequence(after: records)
            let prepare = FakeBacklightJournalEntry(
                sequenceNumber: sequenceNumber,
                requestID: requestID,
                processRole: processRole,
                operationCategory: operationCategory,
                value: value,
                processID: getpid(),
                phase: .prepare,
                previousValue: previousValue
            )
            try appendJournalRecordLocked(
                prepare,
                writePurpose: .journalPrepare,
                syncPurpose: .journalPrepare
            )
            try atomicReplace(
                JSONEncoder().encode(value),
                at: stateURL,
                writePurpose: .stateFile,
                syncPurpose: .stateFile
            )
            let commit = FakeBacklightJournalEntry(
                sequenceNumber: sequenceNumber,
                requestID: requestID,
                processRole: processRole,
                operationCategory: operationCategory,
                value: value,
                processID: getpid(),
                phase: .commit,
                previousValue: previousValue
            )
            try appendJournalRecordLocked(
                commit,
                writePurpose: .journalCommit,
                syncPurpose: .journalCommit
            )
        }
    }

    public func consumeFault() throws -> FakeBacklightFaultAction? {
        try consumeFault(matching: nil)
    }

    public func consumeFault(
        for stage: BacklightStage
    ) throws -> FakeBacklightFaultAction? {
        try consumeFault(matching: stage)
    }

    private func consumeFault(
        matching stage: BacklightStage?
    ) throws -> FakeBacklightFaultAction? {
        try withLock {
            let data = try readBoundedFile(
                faultsURL,
                maximumBytes: Self.maximumFaultFileBytes
            )
            var actions = try JSONDecoder().decode([FakeBacklightFaultAction].self, from: data)
            guard let action = actions.first else {
                return nil
            }
            if case .hang(let expectedStage) = action,
               let stage,
               expectedStage != stage {
                return nil
            }
            actions.removeFirst()
            let replacement = try JSONEncoder().encode(actions)
            guard replacement.count <= Self.maximumFaultFileBytes else {
                throw FakeBacklightDeviceError.oversizedFile(faultsURL.lastPathComponent)
            }
            try atomicReplace(replacement, at: faultsURL)
            return action
        }
    }

    public func recordHangBarrier(
        stage: BacklightStage,
        requestID: BacklightRequestID
    ) throws {
        let barrier = FakeBacklightHangBarrier(
            stage: stage,
            requestID: requestID,
            processID: getpid()
        )
        try withLock {
            try atomicReplace(JSONEncoder().encode(barrier), at: hangBarrierURL(for: stage))
        }
    }

    public func hangBarrier(for stage: BacklightStage) throws -> FakeBacklightHangBarrier? {
        try withLock {
            let url = hangBarrierURL(for: stage)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            try Self.validateExistingFile(url)
            let data = try readBoundedFile(url, maximumBytes: Self.maximumFaultFileBytes)
            return try JSONDecoder().decode(FakeBacklightHangBarrier.self, from: data)
        }
    }

    public func journalEntries() throws -> [FakeBacklightJournalEntry] {
        try withLock {
            let records = try journalRecordsLocked(repairingIncompleteTail: true)
            guard records.contains(where: { isUnresolvedPrepare($0, in: records) }) else {
                return records.filter { $0.phase == .commit }
            }
            let state = try readStateLocked()
            return try recoverJournalLocked(state: state).filter { $0.phase == .commit }
        }
    }

    public func recordProcess(
        requestID: BacklightRequestID,
        value: NormalizedBacklightValue,
        operationCategory: FakeBacklightOperationCategory,
        processID: Int32
    ) throws {
        try withLock {
            try appendJournalLocked(
                requestID: requestID,
                category: operationCategory,
                value: value,
                processID: processID
            )
        }
    }

    private func readStateLocked() throws -> NormalizedBacklightValue {
        let data = try readBoundedFile(stateURL, maximumBytes: Self.maximumFaultFileBytes)
        let decoded = try JSONDecoder().decode(NormalizedBacklightValue.self, from: data)
        guard let validated = try? NormalizedBacklightValue(decoded.rawValue) else {
            throw FakeBacklightDeviceError.invalidState
        }
        return validated
    }

    private func nextSequence(after records: [FakeBacklightJournalEntry]) throws -> UInt64 {
        guard let lastSequence = records.last?.sequenceNumber else { return 1 }
        guard lastSequence < UInt64.max else {
            throw FakeBacklightDeviceError.journalFull
        }
        return lastSequence + 1
    }

    private func recoverJournalLocked(
        state: NormalizedBacklightValue
    ) throws -> [FakeBacklightJournalEntry] {
        var records = try journalRecordsLocked(repairingIncompleteTail: true)
        let unresolved = records.filter { isUnresolvedPrepare($0, in: records) }
        guard let prepare = unresolved.first else { return records }
        guard unresolved.count == 1, prepare.sequenceNumber == records.last?.sequenceNumber else {
            throw FakeBacklightDeviceError.indeterminateTransaction
        }
        guard let previousValue = prepare.previousValue else {
            throw FakeBacklightDeviceError.indeterminateTransaction
        }
        let terminalPhase: FakeBacklightJournalPhase
        if state == prepare.value {
            terminalPhase = .commit
        } else if state == previousValue {
            terminalPhase = .abort
        } else {
            throw FakeBacklightDeviceError.indeterminateTransaction
        }
        let terminal = FakeBacklightJournalEntry(
            sequenceNumber: prepare.sequenceNumber,
            requestID: prepare.requestID,
            processRole: prepare.processRole,
            operationCategory: prepare.operationCategory,
            value: prepare.value,
            processID: prepare.processID,
            phase: terminalPhase,
            previousValue: previousValue
        )
        try appendJournalRecordLocked(
            terminal,
            writePurpose: terminalPhase == .commit ? .journalCommit : .journalEntry,
            syncPurpose: terminalPhase == .commit ? .journalCommit : .journalEntry
        )
        records.append(terminal)
        return records
    }

    private func isUnresolvedPrepare(
        _ candidate: FakeBacklightJournalEntry,
        in records: [FakeBacklightJournalEntry]
    ) -> Bool {
        guard candidate.phase == .prepare else { return false }
        return !records.contains {
            $0.sequenceNumber == candidate.sequenceNumber
                && ($0.phase == .commit || $0.phase == .abort)
        }
    }

    private func journalRecordsLocked(
        repairingIncompleteTail: Bool
    ) throws -> [FakeBacklightJournalEntry] {
        var data = try readBoundedFile(
            journalURL,
            maximumBytes: Self.maximumJournalBytes
        )
        if !data.isEmpty, data.last != 0x0A {
            guard repairingIncompleteTail else {
                throw FakeBacklightDeviceError.invalidFile(journalURL.lastPathComponent)
            }
            let validLength: Int
            if let lastNewline = data.lastIndex(of: 0x0A) {
                validLength = data.distance(
                    from: data.startIndex,
                    to: data.index(after: lastNewline)
                )
            } else {
                validLength = 0
            }
            let descriptor = open(journalURL.path, O_WRONLY | O_NOFOLLOW)
            guard descriptor >= 0 else {
                throw systemCallError("open journal for repair")
            }
            defer { close(descriptor) }
            guard systemCalls.ftruncate(descriptor, length: off_t(validLength)) == 0 else {
                throw systemCallError("truncate journal tail")
            }
            guard systemCalls.fsync(descriptor, purpose: .journalTailRepair) == 0 else {
                throw systemCallError("fsync journal tail repair")
            }
            data = Data(data.prefix(validLength))
        }
        guard !data.isEmpty else { return [] }
        return try data.split(separator: 0x0A).map { line in
            try JSONDecoder().decode(FakeBacklightJournalEntry.self, from: Data(line))
        }
    }

    private func appendJournalLocked(
        requestID: BacklightRequestID,
        category: FakeBacklightOperationCategory,
        value: NormalizedBacklightValue,
        processID: Int32,
        existingRecords: [FakeBacklightJournalEntry]? = nil
    ) throws {
        let existing = try existingRecords ?? journalRecordsLocked(repairingIncompleteTail: true)
        let entry = FakeBacklightJournalEntry(
            sequenceNumber: try nextSequence(after: existing),
            requestID: requestID,
            processRole: processRole,
            operationCategory: category,
            value: value,
            processID: processID
        )
        try appendJournalRecordLocked(
            entry,
            writePurpose: .journalEntry,
            syncPurpose: .journalEntry
        )
    }

    private func appendJournalRecordLocked(
        _ entry: FakeBacklightJournalEntry,
        writePurpose: FakeBacklightWritePurpose,
        syncPurpose: FakeBacklightSyncPurpose
    ) throws {
        let existingSize = try journalFileSizeLocked()
        var record = try JSONEncoder().encode(entry)
        record.append(0x0A)
        guard record.count <= Self.maximumJournalRecordBytes else {
            throw FakeBacklightDeviceError.oversizedJournalRecord
        }
        guard existingSize <= Self.maximumJournalBytes - record.count else {
            throw FakeBacklightDeviceError.journalFull
        }

        let descriptor = open(journalURL.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw systemCallError("open journal")
        }
        defer { close(descriptor) }
        try writeAll(record, to: descriptor, purpose: writePurpose)
        guard systemCalls.fsync(descriptor, purpose: syncPurpose) == 0 else {
            throw systemCallError("fsync journal")
        }
    }

    private func journalFileSizeLocked() throws -> Int {
        var metadata = stat()
        guard lstat(journalURL.path, &metadata) == 0 else {
            throw systemCallError("lstat journal")
        }
        guard metadata.st_size >= 0, metadata.st_size <= Self.maximumJournalBytes else {
            throw FakeBacklightDeviceError.oversizedFile(journalURL.lastPathComponent)
        }
        return Int(metadata.st_size)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = open(lockURL.path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw systemCallError("open lock")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw systemCallError("flock")
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        try Self.validateExistingFile(stateURL)
        try Self.validateExistingFile(faultsURL)
        try Self.validateExistingFile(journalURL)
        return try operation()
    }

    private func readBoundedFile(_ url: URL, maximumBytes: Int) throws -> Data {
        try Self.validateExistingFile(url)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw systemCallError("lstat")
        }
        guard metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
            throw FakeBacklightDeviceError.oversizedFile(url.lastPathComponent)
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw systemCallError("open")
        }
        defer { close(descriptor) }
        return try Self.readAll(from: descriptor, maximumBytes: maximumBytes)
    }

    private func atomicReplace(
        _ data: Data,
        at destination: URL,
        writePurpose: FakeBacklightWritePurpose = .otherFile,
        syncPurpose: FakeBacklightSyncPurpose = .otherFile
    ) throws {
        let temporary = directory.appendingPathComponent(".\(destination.lastPathComponent).tmp")
        if FileManager.default.fileExists(atPath: temporary.path) {
            var metadata = stat()
            guard lstat(temporary.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == geteuid()
            else {
                throw FakeBacklightDeviceError.invalidFile(temporary.lastPathComponent)
            }
            guard unlink(temporary.path) == 0 else {
                throw systemCallError("unlink temporary")
            }
        }
        try writeNewFile(
            data,
            to: temporary,
            writePurpose: writePurpose,
            syncPurpose: syncPurpose
        )
        guard systemCalls.rename(temporary.path, destination.path) == 0 else {
            _ = unlink(temporary.path)
            throw systemCallError("rename")
        }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else {
            throw systemCallError("open directory")
        }
        defer { close(directoryDescriptor) }
        guard systemCalls.fsync(directoryDescriptor, purpose: .stateDirectory) == 0 else {
            throw systemCallError("fsync directory")
        }
    }

    private static func validateDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid()
        else {
            throw FakeBacklightDeviceError.invalidDirectory
        }
    }

    private static func validateExistingFile(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid()
        else {
            throw FakeBacklightDeviceError.invalidFile(url.lastPathComponent)
        }
    }

    private static func writeNewFile(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw systemCallError("create \(url.lastPathComponent)")
        }
        defer { close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw systemCallError("write")
                }
                guard result > 0 else {
                    throw FakeBacklightDeviceError.systemCall("write", EIO)
                }
                offset += result
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw systemCallError("fsync \(url.lastPathComponent)")
        }
    }

    private func writeNewFile(
        _ data: Data,
        to url: URL,
        writePurpose: FakeBacklightWritePurpose,
        syncPurpose: FakeBacklightSyncPurpose
    ) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw Self.systemCallError("create \(url.lastPathComponent)")
        }
        defer { close(descriptor) }
        try writeAll(data, to: descriptor, purpose: writePurpose)
        guard systemCalls.fsync(descriptor, purpose: syncPurpose) == 0 else {
            throw Self.systemCallError("fsync \(url.lastPathComponent)")
        }
    }

    private func writeAll(
        _ data: Data,
        to descriptor: Int32,
        purpose: FakeBacklightWritePurpose
    ) throws {
        systemCalls.beginWrite(purpose, descriptor: descriptor)
        defer { systemCalls.endWrite(descriptor: descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = systemCalls.write(
                    descriptor,
                    buffer: bytes.baseAddress!.advanced(by: offset),
                    count: bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw Self.systemCallError("write")
                }
                guard result > 0 else {
                    throw FakeBacklightDeviceError.systemCall("write", EIO)
                }
                offset += result
            }
        }
    }

    private static func readAll(from descriptor: Int32, maximumBytes: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(4_096, maximumBytes + 1))
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw systemCallError("read")
            }
            if count == 0 { return result }
            result.append(buffer, count: count)
            guard result.count <= maximumBytes else {
                throw FakeBacklightDeviceError.oversizedFile("file")
            }
        }
    }

    private static func systemCallError(_ operation: String) -> FakeBacklightDeviceError {
        FakeBacklightDeviceError.systemCall(operation, errno)
    }

    private func systemCallError(_ operation: String) -> FakeBacklightDeviceError {
        Self.systemCallError(operation)
    }
}
