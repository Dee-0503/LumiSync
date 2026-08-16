# LumiSync App

This directory is the SwiftPM executable target for a native macOS 14+ menu-bar application. Build it with `swift build --product LumiSyncApp` and run the generated executable directly during local development; no paid Apple Developer account, signing identity, privileged helper, or notarization asset is required.

The app links `LumiSyncCore` through `LumiSyncAppSupport`. It reads the active display brightness through public CoreGraphics/IOKit APIs, observes lock, display-sleep, system-sleep, wake, and unlock notifications, persists pause state plus core preferences in `UserDefaults`, and exposes pause/resume from the menu bar.

Input Monitoring is limited to checking/requesting the macOS permission and opening System Settings. No event tap is installed and no key contents are recorded. Keyboard-backlight control uses `KeyboardBacklightControlling`; the production default is `UnavailableKeyboardBacklightController`, so the app visibly reports unavailable instead of pretending a hardware write succeeded.
