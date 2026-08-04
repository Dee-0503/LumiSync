# LumiSync Product Design

**Date:** 2026-08-04  
**Status:** Approved  
**Project:** LumiSync

## 1. Purpose

LumiSync is an open-source native macOS menu-bar application for Apple Silicon MacBooks. It links the active display brightness to the built-in keyboard backlight through user-selectable curves while enforcing immediate backlight shutdown when the display is dark, the session is locked, or the machine sleeps.

The minimum supported operating system is macOS 14 Sonoma. Distribution targets a signed and notarized GitHub release installed through Homebrew Cask.

## 2. Product Requirements

### 2.1 Core behavior

- Monitor display brightness primarily through system events.
- Use an adaptive low-frequency reconciliation timer only when events may have been missed.
- Set the built-in keyboard backlight to zero immediately when:
  - the effective display brightness is zero;
  - the session is locked;
  - the display sleeps;
  - the system sleeps; or
  - an active, non-excluded external keyboard is in use.
- Apply a selected brightness curve whenever no higher-priority rule applies.
- Preserve the current keyboard backlight when the user pauses synchronization.
- Smooth system-driven automatic brightness changes while responding quickly to manual display changes.
- On wake or display-topology changes, resample all state before applying a target.

### 2.2 Curves

The application includes three presets and a custom editor. Every preset is a versioned list of normalized `(display, keyboard)` control points in `[0.0, 1.0]`, evaluated by piecewise-linear interpolation:

- **Comfort (default):** `(0.00, 0.00)`, `(0.01, 1.00)`, `(0.20, 0.75)`, `(0.40, 0.35)`, `(0.60, 0.00)`, `(1.00, 0.00)`.
- **Always On:** `(0.00, 0.00)`, `(0.01, 1.00)`, `(0.30, 0.70)`, `(0.60, 0.40)`, `(1.00, 0.20)`.
- **Energy Saver:** `(0.00, 0.00)`, `(0.01, 0.80)`, `(0.15, 0.45)`, `(0.30, 0.00)`, `(1.00, 0.00)`.
- **Custom:** user-defined control points evaluated by the same interpolation rules.

The intentional discontinuity between display brightness `0.00` and `0.01` implements the mandatory dark-display shutdown. Custom curves must include `(0.00, 0.00)`, use strictly increasing display coordinates, contain between 2 and 16 points, and cannot override the shutdown rule.

A global intensity factor scales the curve output and clamps it to the hardware range. Manual keyboard-backlight changes update this factor through inverse mapping rather than being immediately overwritten.

### 2.3 Display source selection

Select exactly one source deterministically:

1. Use the macOS main display when it is external and readable.
2. Otherwise, inspect readable external displays in ascending `CGDirectDisplayID` order and select the first one.
3. For the same external display, prefer the Apple display adapter over DDC/CI.
4. If no external display is readable, use the built-in display.

Version 1 reads external-display brightness but does not modify it. The settings UI exposes the selected source and a human-readable fallback reason.

### 2.4 External keyboard behavior

- Input Monitoring permission is mandatory for normal operation.
- LumiSync determines which keyboard device generated input but never stores or transmits key contents.
- Connected external keyboards do not affect the backlight until they generate input.
- Input from a non-excluded external keyboard turns off the built-in keyboard backlight.
- Input from the built-in keyboard restores normal synchronization immediately.
- Fifteen minutes without external-keyboard input restores synchronization as a fallback.
- Users can exclude numeric keypads, macro pads, scanners, or other HID devices from this behavior.

### 2.5 Startup and pause

- Login launch is enabled by default after onboarding and Helper installation complete.
- Users can disable login launch in General settings.
- Pausing synchronization preserves the current keyboard-backlight value and returns control to the user.

## 3. Priority State Machine

Each state update is evaluated in the following order. The first matching condition wins:

1. **Required capability unavailable:** Input Monitoring is not authorized or the Helper is unavailable. If synchronization is active, stop it and show an actionable error. If synchronization is already paused, preserve the current value, perform no writes, and show the error.
2. **Inactive session:** locked, display asleep, or system asleep. Immediately set keyboard backlight to zero and suspend timers.
3. **Dark display:** effective display brightness equals zero. Immediately set keyboard backlight to zero without debounce or animation.
4. **External keyboard active:** set keyboard backlight to zero until built-in keyboard input or the 15-minute fallback timeout.
5. **Synchronization paused:** preserve the current value and perform no writes.
6. **Normal operation:** evaluate and apply the active curve.

## 4. Architecture

### 4.1 LumiSync App

A SwiftUI application with AppKit integration provides:

- menu-bar controls and status;
- an onboarding and permissions flow;
- a System Settings-style sidebar window;
- preset selection, intensity adjustment, and curve editing;
- external-keyboard exclusion management;
- login-item configuration;
- display-source, fallback, Helper, and permission diagnostics.

The interface uses native macOS materials and vibrancy. Glass effects are limited to suitable chrome and overlays when they preserve contrast and performance. Curve-editing content uses a stable surface. Reduce Transparency and related accessibility settings are respected.

### 4.2 Sync Engine

A UI-independent business module:

- consumes normalized device and system events;
- evaluates the priority state machine;
- performs curve interpolation and intensity scaling;
- distinguishes fast manual changes from smoothed automatic changes;
- schedules adaptive reconciliation;
- emits idempotent target-backlight commands.

### 4.3 Device Monitor

The monitor produces typed events for:

- built-in and external display brightness;
- display topology changes;
- lock, unlock, sleep, and wake;
- HID input-device identity;
- Input Monitoring authorization changes.

It does not expose specific key values to the rest of the application.

### 4.4 Display Adapters

Adapters share an interface returning a normalized brightness value, capability metadata, and a structured failure reason:

- built-in display adapter;
- Apple external display adapter;
- DDC/CI adapter.

Failure of an external adapter is recoverable and triggers built-in-display fallback.

### 4.5 Privileged Helper

A signed minimal-privilege Helper performs only built-in keyboard-backlight reads and writes. It:

- exposes a narrow XPC protocol;
- verifies the calling application's code signature and requirement;
- rejects untrusted callers;
- has no network, user-document, display-content, or keystroke access;
- is installed, upgraded, and removed through supported macOS service-management mechanisms.

The keyboard-backlight implementation is a technical feasibility gate because macOS does not provide a stable public API for the complete requirement. Product implementation proceeds only after the target Apple Silicon hardware path is verified.

## 5. Data Flow

```text
System / display / HID events
        ↓
Device Monitor and Display Adapters
        ↓
Normalized State Snapshot
        ↓
Priority State Machine
        ↓
Curve + Global Intensity + Smoothing
        ↓
Idempotent Target Command
        ↓ XPC
Privileged Helper
        ↓
Built-in Keyboard Backlight
```

The engine coalesces repeated events and avoids a hardware write when the target has not materially changed.

## 6. Timing and Reconciliation

- A brightness change is classified as manual only when its source event explicitly identifies a user-initiated display-brightness action; every other brightness change is automatic.
- Manual display changes begin synchronization within 300 ms.
- System automatic-brightness changes use a 500 ms debounce and a 1.5-second ease-in-out transition.
- Safety-off transitions are immediate.
- Event delivery is the primary mechanism.
- Reconciliation checks run approximately every 3 seconds during unstable or recently changed conditions and back off to 15 seconds after stability.
- Reconciliation stops during lock and sleep.

Exact intervals remain internal constants and may be tuned through energy and latency measurements; they are not user-facing settings in version 1.

## 7. Persistence

Persist only configuration and non-sensitive device identity metadata:

- selected preset or custom curve;
- global intensity;
- pause state;
- external-keyboard exclusions;
- login-launch preference;
- onboarding completion;
- last known non-sensitive diagnostic state.

Do not persist key contents, input sequences, display contents, or user documents. Preferences must be versioned and migrated explicitly.

## 8. Error Handling

- Missing required permission: stop synchronization and link to the relevant System Settings pane.
- Helper unavailable or incompatible: stop writes, show repair guidance, and never repeatedly request authorization in the background.
- External brightness unavailable: fall back to the built-in display and expose the reason without interrupting the user.
- Invalid custom curve: reject the edit, preserve the last valid curve, and explain the invalid control point.
- DDC timeout: bound the operation, avoid blocking the UI, and temporarily mark the adapter degraded.
- Wake recovery: discard stale transitions, resample all inputs, then apply one fresh target.

## 9. Testing Strategy

### 9.1 Unit tests

- piecewise-linear interpolation and boundary clamping;
- preset definitions and global-intensity scaling;
- inverse mapping from manual keyboard changes;
- priority-state transitions;
- external-keyboard timeout and exclusion behavior;
- display-source selection and fallback reasons;
- smoothing, debounce, coalescing, and reconciliation scheduling;
- preference migration and validation.

### 9.2 Integration tests

- App-to-Helper XPC authorization and rejection of unauthorized clients;
- Helper installation, upgrade, repair, and removal;
- mock display adapters including DDC timeout and failure;
- Input Monitoring permission transitions;
- login-item behavior.

### 9.3 Hardware tests

On supported Apple Silicon MacBooks:

- keyboard-backlight read/write capability;
- manual display brightness and keyboard-backlight keys;
- automatic display brightness;
- lock, display sleep, system sleep, wake, and restart;
- external Apple and DDC displays, including docks and unsupported paths;
- Bluetooth, USB, and receiver-based external keyboards;
- battery impact and wakeup frequency.

### 9.4 Release verification

- Release builds are signed, hardened, and notarized.
- The GitHub artifact checksum matches the Homebrew Cask.
- Installation, upgrade, launch-at-login, Helper installation, and complete uninstall are tested from the published Cask.

## 10. Distribution and Repository Standards

- Source code and release metadata are hosted on GitHub.
- Development uses atomic tasks and isolated branches/worktrees where practical.
- Commits are focused, tested, and follow the repository's documented convention.
- CI runs formatting, static analysis, unit tests, build, signing checks where credentials are available, and release packaging verification.
- Tagged releases publish notarized artifacts and checksums.
- Homebrew distribution uses a Cask; release automation updates the Cask version and checksum.
- Secrets and signing credentials never enter the repository.

## 11. Initial Scope Exclusions

Version 1 does not:

- support Intel Macs or macOS earlier than Sonoma;
- control external keyboard lighting;
- write external-display brightness;
- upload telemetry or input data;
- provide cloud synchronization;
- ship through the Mac App Store;
- promise support for hardware whose keyboard-backlight path fails the feasibility gate.

## 12. Success Criteria

LumiSync version 1 is successful when:

- a supported Apple Silicon MacBook reliably follows the selected curve;
- all safety-off rules apply without visible relighting or race conditions;
- active external-keyboard detection behaves without recording key contents;
- display fallback is transparent and diagnosable;
- idle operation has negligible observable CPU usage and controlled wakeups;
- a fresh user can install a signed release through Homebrew Cask, complete permissions and Helper setup, and obtain automatic login-time operation;
- uninstall removes the App, Helper, and managed launch components cleanly.
