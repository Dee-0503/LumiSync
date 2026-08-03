# LumiSync Helper Boundary

The future privileged Helper has one responsibility: read and set the built-in
keyboard backlight through the `LumiSyncHelperProtocol` application-facing
interface. Values are normalized to the closed range `0.0...1.0`.

The Xcode project phase will adapt this async Swift interface to a narrow XPC
service. That service must verify the calling App's code signature and
designated requirement, reject untrusted callers and out-of-range values, and
use supported macOS service-management mechanisms for installation, upgrades,
repair, and removal.

This scaffold deliberately contains no hardware-control implementation or
private-API assumption. Implementation may proceed only after every check in
`docs/feasibility/keyboard-backlight.md` passes on an Apple Silicon MacBook.

The Helper must not gain network access or access to keystrokes, display
contents, user documents, or other user files.
