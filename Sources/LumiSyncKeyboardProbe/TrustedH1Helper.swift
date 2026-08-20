import Darwin
import Foundation

public enum TrustedH1HelperRole: Sendable {
    case supervisor
    case writer

    fileprivate var executableName: String {
        switch self {
        case .supervisor:
            "lumisync-backlight-supervisor"
        case .writer:
            "lumisync-backlight-writer"
        }
    }
}

public enum TrustedH1Helper {
    public static func resolve(
        _ role: TrustedH1HelperRole,
        relativeTo executableURL: URL
    ) throws -> URL {
        let parent = executableURL.deletingLastPathComponent()
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
        let canonicalParent = parent.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalParent.path == parent.standardizedFileURL.path else {
            throw POSIXError(.EPERM)
        }
        let candidate = parent.appendingPathComponent(role.executableName)
        var info = stat()
        guard lstat(candidate.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o022) == 0,
              access(candidate.path, X_OK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
        return candidate
    }
}
