import Darwin
import Foundation
import LumiSyncKeyboardProbe

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

func format(_ value: Float) -> String {
    String(format: "%.4f", value)
}

do {
    let command = try KeyboardBacklightCommand(
        arguments: Array(CommandLine.arguments.dropFirst())
    )
    let backend = try CoreBrightnessKeyboardBacklightBackend()
    let inspection = try KeyboardBacklightProbe(backend: backend).inspect()
    let builtInKeyboards = inspection.keyboards.filter(\.isBuiltIn)

    guard !builtInKeyboards.isEmpty else {
        throw KeyboardBacklightProbeError.noBuiltInKeyboard
    }

    switch command {
    case .inspect:
        print("mode=read-only")
        print("framework=CoreBrightness (private)")
        print("class=KeyboardBrightnessClient")
        for keyboard in inspection.keyboards {
            print(
                "keyboard id=\(keyboard.id) builtIn=\(keyboard.isBuiltIn) " +
                    "brightness=\(format(keyboard.brightness))"
            )
        }
    case .writeTest:
        guard builtInKeyboards.count == 1, let keyboard = builtInKeyboards.first else {
            fail("write test requires exactly one built-in keyboard backlight")
        }

        print("mode=unsafe-write-test")
        print("keyboard=\(keyboard.id)")
        print("original=\(format(keyboard.brightness))")
        print("recovery=installing SIGINT/SIGTERM/SIGHUP + atexit handlers")
        let result = try KeyboardBacklightWriteTest(backend: backend).run(
            keyboardID: keyboard.id
        )
        print("verified=\(result.verifiedLevels.map(format).joined(separator: ","))")
        print("restored=\(format(result.originalBrightness))")
    }
} catch {
    fail(String(describing: error))
}
