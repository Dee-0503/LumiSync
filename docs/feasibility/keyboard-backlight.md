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

The command exits with `Real writes are blocked until an independent recovery
supervisor is proven.` The library separates a child writer protocol from a
fake-backend recovery policy, but that policy is not a production supervisor.
Fake-backend tests cover the `0.0`, `0.5`, and `1.0` writer sequence, readback
mismatch, child outcomes, restore failure, and restore-readback verification
without touching real hardware.

## Recovery architecture blocker

The reviewed two-process prototype was removed. It ran the private setter/readback
recovery synchronously in the parent watchdog, so a blocked private API call could
hang forever and `SIGKILL` of that parent could prevent restoration entirely. A
process-group runner cannot solve that failure mode by itself, and its successful
fixture paths did not prove that cleanup uncertainty, escaped descendants, signal
handler boundary races, or a hung restore were safe.

Real writes remain unreachable until a separate recovery supervisor owns the
original brightness and survives termination of both the controller and writer.
The required topology is at least:

1. an independent recovery supervisor that owns the original value and a hard
   restore/readback deadline;
2. a controller that requests one bounded write sequence;
3. a writer that cannot daemonize, call `setsid`, change process group, or leave
   descendants, enforced by protocol and integration tests.

Before enabling the writer, deterministic failure-injection tests must prove all of
the following under an outer test-process timeout:

- a hung restore or readback is terminated by a hard deadline and reported as
  unresolved restoration, never as success;
- killing the controller or writer with `SIGKILL` leaves the independent supervisor
  alive to attempt and verify restoration;
- `SIGINT` and `SIGTERM` are blocked while handlers and pending state are changed,
  consumed atomically, then either explicitly re-delivered or returned under a
  documented caller contract;
- signals arriving at handler-install and handler-restore boundaries are not lost;
- primary operation and cleanup failures are returned together, with cleanup or
  restoration uncertainty taking safety precedence;
- handler restore failure, process-group signal failure, leader reap failure, an
  ignored `SIGTERM`, and deadline expiry are injected and asserted;
- the real writer topology rejects `fork`, daemonization, `setsid`, process-group
  escape, and untracked descendants;
- every process test has a hard deadline below five seconds and proves no owned
  processes remain.

Only after the independent writer executable and its authenticated, bounded CLI
protocol are wired to that supervisor may the reference machine attempt `0.0`,
`0.5`, and `1.0`, verify every readback, and verify the final restored value. Any
private setter rejection, timeout, cleanup uncertainty, or restore uncertainty must
leave the App capability unavailable and preserve the complete error context.

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
