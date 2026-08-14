public enum KeyboardBacklightCommand: Equatable, Sendable {
    case inspect
    case writeTest

    public enum ParseError: Error, CustomStringConvertible {
        case incompleteWriteConfirmation
        case writeTestBlocked
        case unsupportedArguments([String])

        public var description: String {
            switch self {
            case .incompleteWriteConfirmation:
                return "Writing requires both --unsafe-write-test and --confirm-restore."
            case .writeTestBlocked:
                return "Real writes are blocked until out-of-process recovery is implemented."
            case let .unsupportedArguments(arguments):
                return "Unsupported arguments: \(arguments.joined(separator: " "))."
            }
        }
    }

    public init(arguments: [String]) throws {
        if arguments.isEmpty {
            self = .inspect
            return
        }

        let flags = Set(arguments)
        let writeFlags: Set<String> = ["--unsafe-write-test", "--confirm-restore"]
        guard flags.isSubset(of: writeFlags) else {
            throw ParseError.unsupportedArguments(arguments)
        }
        guard flags == writeFlags, arguments.count == writeFlags.count else {
            throw ParseError.incompleteWriteConfirmation
        }
        throw ParseError.writeTestBlocked
    }
}
