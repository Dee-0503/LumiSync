# Safe Backlight Control and Distribution Design

**Date:** 2026-08-17  
**Status:** Approved  
**Project:** LumiSync  
**Extends:** `docs/superpowers/specs/2026-08-04-lumisync-design.md`

## 1. Purpose

This specification defines the next development phase for LumiSync: a fail-closed keyboard-backlight control architecture, a reproducible Developer ID distribution path, and a corrected native macOS application icon.

The existing menu-bar application, synchronization engine, display monitoring, keyboard-origin policy, preferences, localization, read-only CoreBrightness probe, and local ad-hoc packaging remain the baseline. This phase does not repeat those features and does not enable production hardware writes merely because read access succeeds.

## 2. Product and Distribution Position

LumiSync is distributed outside the Mac App Store. The production route is:

1. build a reproducible release application bundle;
2. sign the application and every nested executable with Developer ID Application identities and Hardened Runtime;
3. submit the signed archive to Apple Notary Service;
4. staple and validate the notarization ticket;
5. verify Gatekeeper assessment on a clean machine or clean user context;
6. publish an immutable GitHub Release archive and SHA-256 checksum; and
7. install, upgrade, and uninstall the published artifact through Homebrew Cask.

Notarization is malware-oriented automated processing and ticket issuance. It must never be described as App Review, Apple approval of CoreBrightness, a public-API compatibility promise, or permission to use a private framework.

LumiSync does not target the Mac App Store because the complete built-in keyboard-backlight requirement has no documented third-party public API and the proposed adapter uses the private CoreBrightness framework. The implementation must not obfuscate selectors, bypass review, disable System Integrity Protection, request undocumented entitlements, or misrepresent private API use.

## 3. Hardware-Control Boundary

### 3.1 Replaceable private adapter

CoreBrightness is isolated behind a replaceable keyboard-backlight adapter. No App UI, synchronization policy, persistence type, or public application interface may depend on CoreBrightness class names, selectors, dynamic-library paths, keyboard IDs, or Objective-C invocation details.

The adapter may expose only normalized built-in keyboard-backlight operations and structured capability information. It must reject non-finite or out-of-range values before invoking private code.

### 3.2 Capability qualification

A successful read-only probe proves only that the current macOS build exposes a readable path on the current reference machine. It does not qualify writes.

Write qualification is keyed by at least:

- hardware model identifier;
- CPU architecture;
- macOS product version;
- macOS build number;
- CoreBrightness framework presence;
- target class availability;
- required selector availability and expected Objective-C type encodings; and
- completed recovery and readback results.

A macOS build change invalidates previous write qualification by default. Unsupported, changed, ambiguous, or partially verified capability states are unavailable, not best-effort writable.

## 4. Safety Invariants

The following invariants apply to every hardware-control stage:

1. Real writes remain unreachable until the current stage gate explicitly permits them.
2. The independent recovery supervisor exclusively owns the original brightness value and final restoration responsibility.
3. The controller and writer cannot be the sole holders of recovery state.
4. Write, write-readback, restore, and restore-readback operations each have a monotonic hard deadline.
5. A timeout is a terminal operation failure; the caller must not wait indefinitely for private framework code.
6. Every accepted write is followed by readback verification within a declared tolerance.
7. Restoration uncertainty takes precedence over primary-operation success or failure.
8. If restoration cannot be verified, the capability becomes unavailable and remains fail-closed until a fresh health and qualification cycle succeeds.
9. Killing the controller or writer with `SIGINT`, `SIGTERM`, `SIGABRT`, or `SIGKILL` must not prevent the supervisor from attempting and verifying restoration.
10. Owned writer processes must not daemonize, call `setsid`, escape their assigned process group, retain uncontrolled descendants, or remain after the operation deadline.
11. Tests must detect and fail on surviving owned processes after cleanup.
12. The protocol must not accept arbitrary selectors, dynamic-library paths, shell commands, executable paths, device IDs, serialized Objective-C messages, or unrestricted file paths.
13. No component may read, record, persist, or transmit key contents, characters, keycodes, input sequences, display contents, or user documents.
14. No component gains network access merely to perform hardware control.
15. Any unknown state is treated as unavailable.

## 5. Three-Process Recovery Architecture

```text
LumiSync App
    ↓ bounded application request
Controller
    ↓ narrow operation request
Independent Recovery Supervisor
    ↓ one-shot writer instruction
Writer
    ↓ replaceable adapter
CoreBrightness private framework
```

The logical roles must be independently testable. H1 uses separate executable processes with a fake adapter. Later stages may package roles as signed services only if process independence and the recovery ownership invariants remain true.

### 5.1 Controller

The controller translates an application request into one bounded operation. It:

- assigns a unique request identifier;
- validates normalized values;
- rejects concurrent conflicting operations according to a documented serialization rule;
- reports supervisor health and structured operation results;
- never owns the only copy of original brightness; and
- does not report success until readback verification succeeds.

### 5.2 Independent Recovery Supervisor

The supervisor is the recovery authority. For each accepted operation it:

1. validates the request and deadline budget;
2. reads and validates the original brightness through a bounded one-shot writer;
3. stores the original value in supervisor-owned memory before permitting a mutation;
4. launches a separate one-shot writer for the requested value;
5. requires write readback within tolerance;
6. restores the original value after completion, controller loss, writer failure, cancellation, signal, timeout, or protocol violation;
7. verifies restoration through an independent readback; and
8. terminates the owned process group and reports whether restoration is verified, failed, or uncertain.

The supervisor must remain alive when the controller or writer dies. Supervisor death cannot be claimed as recoverable by the same supervisor. H1 therefore proves controller/writer failure containment; later design work must define operating-system lifecycle behavior and startup reconciliation for supervisor loss before production writes are enabled.

### 5.3 Writer

The writer is a short-lived, single-purpose process. It:

- accepts exactly one typed instruction from the supervisor;
- supports read, write-and-readback, and restore-and-readback operations;
- validates all inputs;
- invokes only the selected adapter operation;
- emits one structured result;
- creates no descendants;
- does not daemonize or detach; and
- exits after the result or deadline.

The supervisor treats malformed output, extra output, unexpected process topology, signal death, timeout, or readback mismatch as failure.

## 6. Protocol and Result Model

H1 uses a versioned, length-bounded protocol suitable for local process tests. The production transport may become XPC in H3, but semantic types remain transport-independent.

Required concepts:

- `BacklightRequestID`: opaque unique request identifier.
- `BacklightOperation`: read, set normalized brightness, or restore normalized brightness.
- `BacklightDeadline`: monotonic deadline represented as a remaining duration at process boundaries, never wall-clock time.
- `BacklightReadback`: normalized observed value and tolerance result.
- `BacklightSupervisorHealth`: healthy, degraded with reason, or unavailable with reason.
- `BacklightOperationResult`: success with verified readback; rejected; timed out; writer failed; readback mismatched; restoration verified after primary failure; restoration failed; or restoration uncertain.

Result ordering rules:

1. restoration failed or uncertain outranks every primary result;
2. restoration verified after primary failure reports the primary failure plus verified recovery;
3. success requires requested-value readback verification and, for bounded qualification tests, verified restoration;
4. malformed or unknown result values are unavailable failures.

Protocol payloads have explicit maximum sizes and reject unknown versions. Diagnostics may contain stable error categories and numeric values but not secrets, user content, raw Objective-C objects, or unrestricted environment details.

## 7. Application-Facing Control API

The current synchronous interface is insufficient because it cannot express deadlines, cancellation, readback, supervisor health, or restoration uncertainty. Before H4, it is replaced with an asynchronous bounded interface semantically equivalent to:

```swift
public protocol KeyboardBacklightControlling: Sendable {
    var availability: KeyboardBacklightAvailability { get async }

    func setBrightness(
        _ value: Double,
        deadline: ContinuousClock.Instant
    ) async -> KeyboardBacklightOperationResult
}
```

Exact implementation types are set by the implementation plan, but these rules are fixed:

- calls never block the main actor on private framework work;
- cancellation requests cleanup but does not suppress restoration;
- callers receive a structured result rather than inferring success from absence of an error;
- repeated materially identical targets are coalesced;
- a safety-off target bypasses normal debounce and animation;
- degraded supervisor health immediately changes App capability to unavailable; and
- the App remains wired to `UnavailableKeyboardBacklightController` until H4 passes.

## 8. Staged Hardware Gates

### H1: Fake multi-process safety proof

H1 contains no CoreBrightness writes. It must prove the controller/supervisor/writer topology with a deterministic fake device shared across process boundaries.

Pass criteria:

- original value is captured before mutation authorization;
- `0.0`, `0.5`, and `1.0` fake writes receive readback verification;
- normal completion restores and verifies the original value;
- controller and writer `SIGINT`, `SIGTERM`, `SIGABRT`, and `SIGKILL` cases restore and verify;
- hung read, write, readback, restore, and restore-readback operations terminate at hard deadlines;
- malformed protocol messages and unknown versions are rejected;
- writer launch failure and partial output are contained;
- fork, daemonization, `setsid`, process-group escape, and descendant-survival attempts fail the test suite;
- restoration failure and restoration uncertainty dominate result reporting;
- every test has its own outer timeout; and
- no owned process survives test cleanup.

H1 does not unblock real writes. It authorizes development of H2 only after independent code review and fresh CI pass.

### H2: Reference-machine controlled qualification

H2 is a separately authorized, local-only qualification tool for a named Apple Silicon reference machine and exact macOS build. It is not part of normal App behavior.

Before the first real write, H2 must:

- pass all H1 tests unchanged;
- confirm selector presence and expected Objective-C type encodings;
- read a finite original brightness in `0.0...1.0`;
- arm the independent supervisor with the original value;
- use conservative operation and restoration deadlines;
- write only the bounded qualification sequence `0.0`, `0.5`, and `1.0`;
- verify readback after every write;
- restore and verify the original value after every individual level, not only at the end;
- record only non-sensitive qualification metadata and result categories; and
- fail closed on any mismatch, timeout, signal, process leak, unsupported state, or uncertain restoration.

H2 requires explicit user authorization at execution time. The existing `writeTestBlocked` guard remains in place until the H2 implementation has passed review; adding H2 code is not itself authorization to execute it.

### H3: Signed local service and caller authentication

H3 packages the qualified behavior behind the least-privileged supported macOS service topology. A root privileged Helper is not assumed. The implementation must first demonstrate whether a normal user-scoped signed XPC or ServiceManagement service can perform the qualified operation.

The service must:

- expose only typed normalized backlight operations and health checks;
- authenticate the caller using audit token evidence, Team ID, bundle identifier, and designated requirement;
- reject unsigned, differently signed, malformed, replayed, or unauthorized requests;
- have no network, keystroke, display-content, or user-document access;
- support signed installation, upgrade, repair, and removal;
- preserve independent supervisor recovery responsibility; and
- become unavailable when code-signing or qualification identity does not match.

Privilege escalation is considered only if ordinary-user operation is proven insufficient and a new reviewed specification demonstrates why it is necessary.

### H4: App integration

H4 replaces the unavailable production controller only after H1–H3 pass. Integration must:

- use the asynchronous bounded control API;
- serialize or supersede requests deterministically;
- coalesce materially identical targets using a tested epsilon;
- cancel stale transitions without canceling required restoration;
- apply immediate safety-off behavior;
- expose supervisor health and actionable unavailable reasons;
- return to fail-closed after service loss, OS build change, readback mismatch, timeout, or uncertain restoration; and
- retain a user-visible pause mode that performs no writes.

## 9. Distribution Gates

### D1: Reproducible unsigned release bundle

D1 builds a complete release-shaped `.app` from source without signing credentials. It must:

- use a clean output directory;
- build release binaries for Apple Silicon and macOS 14+;
- embed localized resources and the corrected icon;
- embed every required nested executable at deterministic paths;
- generate `Info.plist` values from explicit version inputs;
- produce a manifest of nested code and expected identifiers;
- reject missing, duplicate, unexpected, or writable executable locations;
- avoid absolute development paths and `.build` runtime dependencies; and
- support deterministic structural verification in CI.

D1 does not claim distributable trust or normal-user warning-free installation.

### D2: Developer ID, Hardened Runtime, and notarization

D2 consumes the D1 bundle and signing credentials from Keychain or CI secret storage. It must:

- sign nested code inside-out with explicit identities and entitlements;
- sign the outer App last;
- verify each nested signature, identifier, Team ID, requirement, and Hardened Runtime flag;
- archive the exact signed App submitted to Notary Service;
- staple and validate the ticket on the App and final archive as applicable;
- run `codesign --verify --deep --strict` and `spctl --assess`;
- test launch and service authentication under Gatekeeper; and
- preserve notarization logs without exposing credentials.

Credentials, passwords, API keys, profiles, certificates, and session tokens never enter the repository.

### D3: GitHub Release and Homebrew Cask

D3 requires explicit publication authorization. It must:

- publish an immutable versioned GitHub Release asset;
- compute and publish its SHA-256 checksum;
- replace `0.1.0-dev` and `sha256 :no_check` in the Cask;
- verify the Cask URL resolves to the immutable asset;
- test clean install, upgrade, launch, service installation, service removal, uninstall, and zap behavior;
- verify no managed service or owned process remains after uninstall; and
- document private API and support boundaries without claiming Apple approval.

## 10. Native macOS Icon Track

The approved visual metaphor remains a blue display, amber keyboard, and a blue-to-amber synchronization light. The current packaged asset is rejected because an inner rounded motif sits on an opaque square canvas.

The replacement icon must:

- use a native macOS squircle silhouette;
- have transparent pixels outside the squircle, including all four outer corners;
- contain no dark rectangular backing plate beyond the silhouette;
- use balanced system-style optical margins;
- simplify screen, keyboard, keycap, border, and highlight details for 16–64 px legibility;
- preserve clear blue-display, amber-keyboard, and synchronization-light recognition;
- avoid text and generic lightbulb imagery;
- produce a complete `.icns` representation set; and
- match the apparent size and silhouette of neighboring native macOS icons in Finder and Launchpad.

Automated acceptance checks verify alpha in the four corners, required representation sizes, valid `.icns` extraction, and application bundle linkage. Final acceptance also requires a visual comparison against neighboring native macOS icons at normal Finder sizes.

## 11. Testing and CI

### 11.1 H1 process tests

Process tests run with deterministic fake state and explicit per-test deadlines. They assert process exit, process-group cleanup, state restoration, readback, and result precedence. Test utilities may inspect only processes they create and identify.

### 11.2 Protocol and unit tests

Unit tests cover:

- payload size and version validation;
- normalized numeric validation;
- request serialization and duplicate handling;
- deadline budget propagation;
- result precedence;
- capability invalidation by OS build;
- selector type-encoding qualification;
- App target coalescing and safety-off bypass; and
- caller-authentication decision logic using synthetic identity evidence.

### 11.3 Bundle tests

CI verifies:

- expected bundle layout;
- localized resources;
- icon representations and alpha corners;
- nested executable manifest;
- absence of development-path dependencies;
- deterministic version metadata; and
- honest failure of signing/notarization stages when credentials are unavailable.

Credentialed signing and notarization jobs are separate protected release jobs, not prerequisites for ordinary pull-request tests.

## 12. Diagnostics and Privacy

Diagnostics may expose:

- capability state and stable reason category;
- qualified hardware and OS build identifiers;
- supervisor health;
- operation request identifier;
- deadline category;
- requested and observed normalized brightness; and
- whether restoration was verified, failed, or uncertain.

Diagnostics must not expose keys, keycodes, input sequences, screen data, arbitrary environment variables, user files, signing secrets, notarization credentials, or raw private-framework objects.

Logs use bounded retention and avoid high-frequency normal-operation spam.

## 13. Development Order and Parallel Tracks

Development begins with three independent tracks:

1. **H1 safety track:** fake multi-process protocol, supervisor, writer, controller, and process fault injection.
2. **Icon track:** transparent squircle master, `.icns` generation, automated alpha checks, and Finder visual acceptance.
3. **D1 bundle track:** reproducible release-shaped unsigned App with nested executable manifest and structural verification.

H2 depends on H1. H3 depends on H2. H4 depends on H1–H3. D2 depends on D1 and available Developer ID credentials. D3 depends on D2 and explicit publication authorization.

Parallel work must use isolated Orca-managed worktrees when writers would otherwise conflict. Commits remain focused and follow `type: subject`. Generated builds, local signing products, notarization outputs, `.claude/`, and `.firecrawl/` are never committed.

## 14. Explicit Non-Goals for This Phase

This phase does not:

- enable real writes before H2 authorization and qualification;
- wire a CoreBrightness controller into the production App before H4;
- target the Mac App Store;
- claim notarization approves or supports private API use;
- introduce a root Helper without evidence and a new reviewed design;
- control external keyboard lighting;
- write external-display brightness;
- disable SIP or Gatekeeper;
- request undocumented entitlements;
- add telemetry or cloud services; or
- publish a GitHub Release or Homebrew update without explicit authorization.

## 15. Stage Exit Criteria

The project has entered development when:

- this specification and its implementation plan are committed on the dedicated development branch;
- H1, icon, and D1 tasks have concrete test-first work items;
- at least the first H1 failing tests are implemented and observed failing for the intended missing behavior; and
- the production App and CLI still prove that real writes are blocked.

Production hardware control is ready only when H1–H4 pass with fresh evidence. Public distribution is ready only when D1–D3 pass with fresh evidence.
