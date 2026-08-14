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
        fail("write test is unreachable until the watchdog gate passes")
    }
} catch {
    fail(String(describing: error))
}
