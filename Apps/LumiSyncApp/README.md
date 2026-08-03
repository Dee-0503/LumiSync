# LumiSync App Scaffold

This directory defines the native macOS application boundary for the future
Xcode project. Add `LumiSyncApp.swift` and `SettingsView.swift` to a macOS 14+
app target, then link that target to the `LumiSyncCore` Swift package product.

The scaffold provides a menu-bar scene and a settings scene. It consumes the
versioned default preferences from `LumiSyncCore` and presents placeholder
diagnostics until the device monitors and Helper client are connected.

No hardware access is implemented here. The App must communicate with the
privileged Helper through the narrow interface documented in
`Helpers/LumiSyncHelper`, and keyboard-backlight control must not be connected
until `docs/feasibility/keyboard-backlight.md` passes on target hardware.
