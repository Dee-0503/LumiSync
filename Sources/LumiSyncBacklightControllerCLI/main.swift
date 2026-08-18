import Darwin
import Foundation
import LumiSyncKeyboardProbe

let codec = FramedJSONCodec()
let input = FileHandle.standardInput.readDataToEndOfFile()

if (try? codec.decode(BacklightRequest.self, from: input)) == nil {
    let rejection = BacklightOperationResult.failure(
        primary: .protocolViolation,
        restoration: .notRequired
    )
    do {
        try FileHandle.standardOutput.write(contentsOf: codec.encode(rejection))
        exit(EX_OK)
    } catch {
        FileHandle.standardError.write(Data("invalid rejection frame\n".utf8))
        exit(EX_PROTOCOL)
    }
}

FileHandle.standardError.write(Data("H1 executable not configured\n".utf8))
exit(EX_UNAVAILABLE)
