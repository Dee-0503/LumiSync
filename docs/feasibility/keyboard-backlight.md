# Keyboard Backlight Feasibility Gate

## Result on the reference machine

Read-only probe passed on 2026-08-14 with:

- Apple M4 MacBook Air (`arm64`)
- macOS 15.6.1 (24G90)
- Xcode 26.1.1 (17B100)
- Swift 6.2.1

The probe discovered one built-in keyboard backlight (`id=95158272`) and read its
normalized brightness as `0.0000`. No real write was performed.

Current gate status: **read passes; real write remains blocked.**

## Prototype

Build and run the default read-only command:

```sh
swift run lumisync-keyboard-probe
```

The default mode loads the private framework at runtime, enumerates keyboard
backlight IDs, checks whether each device is built in, and reads its brightness.
It does not call a setter.

The CLI requires both explicit write confirmations, but still fails closed:

```sh
swift run lumisync-keyboard-probe --unsafe-write-test --confirm-restore
```

The command exits with `Real writes are blocked until out-of-process recovery is
implemented.` The library now separates a child writer protocol from a parent
recovery watchdog. Fake-backend tests cover the `0.0`, `0.5`, and `1.0` writer
sequence, readback mismatch, normal child completion, thrown child-launch errors,
`SIGINT`, `SIGTERM`, crash, kill, `SIGKILL`, restore failure, and restore-readback
verification.

## Watchdog blocker

A first POSIX child-process runner was intentionally removed after its integration
tests left shell children behind and could hang beyond the five-second test budget.
The fake protocol proves the parent recovery policy, but it does not prove that the
real process runner always forwards termination, bounds `waitpid`, and reaps the
writer without orphaning descendants. Therefore the safety gate is not met and the
hardware setter remains unreachable from the CLI.

Before enabling real writes, add a deterministic process harness with all of these
properties:

- every external-process test has a hard deadline below five seconds;
- timeout cleanup kills the complete writer process group and reaps it;
- normal exit, Swift throw, `SIGINT`, `SIGTERM`, crash, explicit kill, and `SIGKILL`
  are exercised without orphan processes;
- the parent independently owns keyboard ID and original brightness;
- the parent restores and reads back the original brightness after every child
  outcome;
- any restore or verification uncertainty fails closed.

Only after that harness passes the filtered and full test suites may the reference
machine set `0.0`, `0.5`, and `1.0`, verify every readback, and confirm the final
value equals the captured original value.

## API research

No public Apple SDK API was found for third-party control of the built-in keyboard
backlight. The working read path on this machine is the private framework:

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

The legacy Intel-era `AppleLMUController` IORegistry service was not present. The
built-in keyboard appears as `AppleHIDKeyboardEventDriverV2`, but its public
IORegistry properties do not expose a supported normalized keyboard-backlight
setter.

## Permissions and platform risk

On this reference machine, the read-only private API worked as an ordinary unsigned
SwiftPM executable with no root access, TCC prompt, special entitlement, or SIP
change. It does not access key events, key contents, screen contents, or user files.

The private API has no source or binary compatibility guarantee. Class names,
selectors, type encodings, keyboard ID semantics, return conventions, access checks,
and daemon behavior may change in any macOS update. Private framework use is
unsuitable for Mac App Store distribution and may be rejected during review. SIP
must not be disabled, and undocumented Apple entitlements must not be requested or
forged.
