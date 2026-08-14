# Keyboard Backlight Feasibility Gate

## Result on the reference machine

Read-only probe passed on 2026-08-14 with:

- Apple M4 MacBook Air (`arm64`)
- macOS 15.6.1 (24G90)
- Xcode 26.1.1 (17B100)
- Swift 6.2.1

The probe discovered one built-in keyboard backlight (`id=95158272`) and read its
normalized brightness as `0.0000`. No write was performed during development or
verification because recovery behavior was validated with a fake backend, but
termination-time recovery cannot be proven safe enough for an unattended real
hardware test: POSIX signal handlers cannot safely invoke Objective-C/private
framework code.

Current gate status: **read passes; real write remains blocked pending an
out-of-process recovery watchdog or equivalent crash-safe mechanism.**

## Prototype

Build and run the default read-only command:

```sh
swift run lumisync-keyboard-probe
```

The default mode loads the private framework at runtime, enumerates keyboard
backlight IDs, checks whether each device is built in, and reads its brightness.
It does not call a setter.

A write-test path is implemented behind the library boundary, but the CLI keeps
all real writes blocked until crash-safe out-of-process recovery exists. Even both
explicit flags fail closed:

```sh
swift run lumisync-keyboard-probe --unsafe-write-test --confirm-restore
```

The command exits with `Real writes are blocked until out-of-process recovery is
implemented.` The library flow reads the original value first, installs recovery,
writes `0.0`, `0.5`, and `1.0` with readback checks, then restores the original
value. Fake-backend unit tests prove ordering, error-path restoration, refusal to
write without recovery, and keeping recovery armed after a failed restore. They
do not prove restoration after `SIGKILL`, a process crash, power loss, or an unsafe
signal callback, so the hardware setter is not reachable from the prototype CLI.

## API research

No public Apple SDK API was found for third-party control of the built-in
keyboard backlight. The working path on this machine is the private framework:

- Framework: `/System/Library/PrivateFrameworks/CoreBrightness.framework`
- Objective-C class: `KeyboardBrightnessClient`
- Observed instance selectors and encodings:
  - `copyKeyboardBacklightIDs` → `@16@0:8`
  - `isKeyboardBuiltIn:` → `B24@0:8Q16`
  - `brightnessForKeyboard:` → `f24@0:8Q16`
  - `backlightLevelForKeyboard:` → `f24@0:8Q16`
  - `setBrightness:forKeyboard:` → `B28@0:8f16Q20`
  - `setBrightness:fadeSpeed:commit:forKeyboard:` → `B36@0:8f16i20B24Q28`

Related exported CoreBrightness symbols observed in the dyld shared cache include
`CBALCKeyboardFeatureAvailable`, `CBALCGetKeyboardAutoBrightnessEnabled`, and
`CBALCSetKeyboardAutoBrightnessEnabled`. Those control availability/preferences,
not the normalized manual brightness used by this prototype.

The framework executable is represented through the dyld shared cache on this OS;
the on-disk framework binary symlink appears broken to ordinary filesystem tools,
while `Bundle.load()` and runtime class lookup succeed. Static linking or assuming
a physical Mach-O at the symlink is therefore inappropriate.

The legacy Intel-era `AppleLMUController` IORegistry service was not present.
The built-in keyboard appears as `AppleHIDKeyboardEventDriverV2`, but its public
IORegistry properties do not expose a supported normalized keyboard-backlight
setter. Direct IOKit user-client reverse engineering was not needed for the
read-only prototype and would increase compatibility and privilege risk.

## Permissions and platform risk

On this reference machine, the read-only private API worked as an ordinary
unsigned SwiftPM executable:

- no root access;
- no TCC prompt;
- no special entitlement;
- no SIP change;
- no access to key events, key contents, screen contents, or user files.

The private API has no source or binary compatibility guarantee. Class names,
selectors, type encodings, keyboard ID semantics, return conventions, access
checks, and daemon behavior may change in any macOS update. Private framework use
is unsuitable for Mac App Store distribution and may be rejected during review.
Hardened Runtime, sandboxing, notarization, or future entitlement checks may also
change whether runtime loading or writes are accepted. SIP must not be disabled,
and undocumented Apple entitlements must not be requested or forged.

## Required next step before real writes

Implement a minimal out-of-process recovery watchdog before executing the hardware
write test. The parent should hold the original value and monitor a short-lived
writer; if the writer exits, crashes, or is terminated before reporting successful
restoration, the parent must restore the original brightness independently. The
watchdog itself must be tested against normal completion, thrown errors, `SIGINT`,
`SIGTERM`, and forced writer termination. `SIGKILL`, kernel failure, and power loss
remain unavoidable residual risks and must be documented in the operator prompt.

Only after that mechanism passes should the reference-machine test set `0.0`,
`0.5`, and `1.0`, verify each readback, and confirm the final value equals the
captured original value.
