import Darwin
import Foundation

FileHandle.standardError.write(Data("H1 executable not configured\n".utf8))
exit(EX_UNAVAILABLE)
