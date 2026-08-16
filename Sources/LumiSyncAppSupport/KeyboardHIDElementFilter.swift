enum KeyboardHIDElementFilter {
    private static let keyboardOrKeypadUsagePage: UInt32 = 0x07
    private static let ordinaryKeyUsageRanges: [ClosedRange<UInt32>] = [
        0x04...0x38, // Alphanumeric, editing, and punctuation keys; excludes Caps Lock.
        0x3A...0x45, // F1 through F12.
        0x49...0x52, // Insert through arrow keys.
        0x53...0x64, // Keypad lock/operators/digits and the non-US backslash key.
        0x67...0x73  // Keypad equals and F13 through F24.
    ]

    static func isOrdinaryKeyPress(
        usagePage: UInt32,
        usage: UInt32,
        integerValue: Int
    ) -> Bool {
        usagePage == keyboardOrKeypadUsagePage
            && integerValue != 0
            && ordinaryKeyUsageRanges.contains { $0.contains(usage) }
    }
}
