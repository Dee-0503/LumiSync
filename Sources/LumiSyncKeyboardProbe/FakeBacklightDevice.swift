import Darwin
import Foundation

public enum FakeBacklightDeviceError: Error, Equatable, Sendable {
    case invalidDirectory
    case invalidFile(String)
    case oversizedFile(String)
    case invalidState
    case oversizedJournalRecord
    case journalFull
    case systemCall(String, Int32)
}

public enum FakeBacklightFaultAction: Codable, Equatable, Sendable {
    case returnValue(NormalizedBacklightValue)
    case sleepNanoseconds(UInt64)
    case exit(code: Int32)
    case raise(signal: Int32)
    case malformedOutput
    case forkSleepingChild
    case attemptSetsid
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

public struct FakeBacklightJournalEntry: Codable, Equatable, Sendable {
    public let sequenceNumber: UInt64
    public let requestID: BacklightRequestID
    public let processRole: FakeBacklightProcessRole
    public let operationCategory: FakeBacklightOperationCategory
    public let value: NormalizedBacklightValue
    public let processID: Int32

    public init(
        sequenceNumber: UInt64,
        requestID: BacklightRequestID,
        processRole: FakeBacklightProcessRole,
        operationCategory: FakeBacklightOperationCategory,
        value: NormalizedBacklightValue,
        processID: Int32
    ) {
        self.sequenceNumber = sequenceNumber
        self.requestID = requestID
        self.processRole = processRole
        self.operationCategory = operationCategory
        self.value = value
        self.processID = processID
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

    public init(
        directory: URL,
        processRole: FakeBacklightProcessRole = .test
    ) throws {
        self.directory = directory.standardizedFileURL
        self.processRole = processRole
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
            try appendJournalLocked(
                requestID: requestID,
                category: .read,
                value: value
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
            try atomicReplace(JSONEncoder().encode(value), at: stateURL)
            try appendJournalLocked(
                requestID: requestID,
                category: operationCategory,
                value: value
            )
        }
    }

    public func consumeFault() throws -> FakeBacklightFaultAction? {
        try withLock {
            let data = try readBoundedFile(
                faultsURL,
                maximumBytes: Self.maximumFaultFileBytes
            )
            var actions = try JSONDecoder().decode([FakeBacklightFaultAction].self, from: data)
            guard !actions.isEmpty else {
                return nil
            }
            let action = actions.removeFirst()
            let replacement = try JSONEncoder().encode(actions)
            guard replacement.count <= Self.maximumFaultFileBytes else {
                throw FakeBacklightDeviceError.oversizedFile(faultsURL.lastPathComponent)
            }
            try atomicReplace(replacement, at: faultsURL)
            return action
        }
    }

    public func journalEntries() throws -> [FakeBacklightJournalEntry] {
        try withLock {
            let data = try readBoundedFile(
                journalURL,
                maximumBytes: Self.maximumJournalBytes
            )
            guard !data.isEmpty else {
                return []
            }
            return try data.split(separator: 0x0A).map { line in
                try JSONDecoder().decode(FakeBacklightJournalEntry.self, from: Data(line))
            }
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

    private func appendJournalLocked(
        requestID: BacklightRequestID,
        category: FakeBacklightOperationCategory,
        value: NormalizedBacklightValue
    ) throws {
        let existing = try readBoundedFile(
            journalURL,
            maximumBytes: Self.maximumJournalBytes
        )
        let lastSequence: UInt64
        if let lastLine = existing.split(separator: 0x0A).last {
            lastSequence = try JSONDecoder()
                .decode(FakeBacklightJournalEntry.self, from: Data(lastLine))
                .sequenceNumber
        } else {
            lastSequence = 0
        }
        guard lastSequence < UInt64.max else {
            throw FakeBacklightDeviceError.journalFull
        }
        let entry = FakeBacklightJournalEntry(
            sequenceNumber: lastSequence + 1,
            requestID: requestID,
            processRole: processRole,
            operationCategory: category,
            value: value,
            processID: getpid()
        )
        var record = try JSONEncoder().encode(entry)
        record.append(0x0A)
        guard record.count <= Self.maximumJournalRecordBytes else {
            throw FakeBacklightDeviceError.oversizedJournalRecord
        }
        guard existing.count <= Self.maximumJournalBytes - record.count else {
            throw FakeBacklightDeviceError.journalFull
        }

        let descriptor = open(journalURL.path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw systemCallError("open journal")
        }
        defer { close(descriptor) }
        try Self.writeAll(record, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw systemCallError("fsync journal")
        }
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

    private func atomicReplace(_ data: Data, at destination: URL) throws {
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
        try Self.writeNewFile(data, to: temporary)
        guard rename(temporary.path, destination.path) == 0 else {
            _ = unlink(temporary.path)
            throw systemCallError("rename")
        }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else {
            throw systemCallError("open directory")
        }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
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
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw systemCallError("fsync \(url.lastPathComponent)")
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
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
