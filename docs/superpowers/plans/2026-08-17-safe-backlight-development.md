# Safe Backlight Development Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enter the next LumiSync development phase by proving a fake three-process recovery architecture, replacing the malformed square icon with a transparent native macOS squircle, and producing a reproducible unsigned release-shaped application bundle.

**Architecture:** Add a transport-independent safety protocol and deterministic fake device to `LumiSyncKeyboardProbe`, then run separate controller, supervisor, and one-shot writer executables in process-level tests. Keep icon production and unsigned bundle assembly as parallel tracks, converging only when the D1 bundle embeds the approved icon and H1 executables. Preserve the production App's unavailable controller and the CLI real-write block until later H2–H4 gates pass.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation, Darwin process APIs, XCTest, Bash, Python 3 standard library, macOS `iconutil`, `sips`, `plutil`, `otool`, and GitHub Actions on macOS.

**Spec:** `docs/superpowers/specs/2026-08-17-safe-backlight-distribution-design.md`

## Global Constraints

- Minimum OS: macOS 14 Sonoma on Apple Silicon MacBooks.
- CoreBrightness remains a replaceable private adapter; H1 performs no CoreBrightness writes.
- `KeyboardBacklightCommand.writeTestBlocked` remains the public CLI result for real-write flags throughout this plan.
- `Apps/LumiSyncApp/LumiSyncApp.swift` continues injecting `UnavailableKeyboardBacklightController` throughout this plan.
- Supervisor-owned restoration state must never be delegated exclusively to the controller or writer.
- Read, write, readback, restore, and restore-readback operations use monotonic hard deadlines.
- Restoration failure or uncertainty outranks every primary operation result.
- No process may accept arbitrary selectors, dynamic-library paths, shell commands, executable paths, keyboard IDs, or unrestricted file paths from an App-facing request.
- No component reads, stores, or transmits key contents, characters, keycodes, input sequences, display contents, or user documents.
- The App icon uses a native macOS squircle with transparent outer corners and no opaque square backing plate.
- D1 output is unsigned release-shaped structure and must not be represented as Developer ID signed, notarized, Gatekeeper-ready, or warning-free distribution.
- Generated builds, local signing products, notarization outputs, `.claude/`, and `.firecrawl/` are never committed.
- Commits are focused and use `type: subject`.

---

## File Structure

### H1 safety track

- `Sources/LumiSyncKeyboardProbe/SafetyProtocol.swift` — versioned request/result types, normalized value validation, payload limits, and restoration-result precedence.
- `Sources/LumiSyncKeyboardProbe/Qualification.swift` — hardware/OS qualification identity and build-change invalidation, without enabling writes.
- `Sources/LumiSyncKeyboardProbe/FramedJSON.swift` — length-bounded single-message JSON framing used only between owned local processes.
- `Sources/LumiSyncKeyboardProbe/FakeBacklightDevice.swift` — file-backed fake brightness state, operation script, and atomic event journal for cross-process H1 tests.
- `Sources/LumiSyncKeyboardProbe/BoundedProcess.swift` — executable launch, process-group containment, monotonic deadline enforcement, structured output capture, and owned-process cleanup.
- `Sources/LumiSyncKeyboardProbe/SafetySupervisor.swift` — supervisor state machine that captures the original value, launches one-shot writers, restores, verifies, and applies result precedence.
- `Sources/LumiSyncKeyboardProbe/SafetyController.swift` — normalized request validation, request serialization, and supervisor invocation.
- `Sources/LumiSyncBacklightWriterCLI/main.swift` — one-shot fake writer executable for H1.
- `Sources/LumiSyncBacklightSupervisorCLI/main.swift` — one-request supervisor executable for H1.
- `Sources/LumiSyncBacklightControllerCLI/main.swift` — test-facing controller executable for H1.
- `Tests/LumiSyncKeyboardProbeTests/SafetyProtocolTests.swift` — pure protocol, value, size, version, deadline, and precedence tests.
- `Tests/LumiSyncKeyboardProbeTests/QualificationTests.swift` — OS-build qualification invalidation tests.
- `Tests/LumiSyncKeyboardProbeTests/FakeBacklightDeviceTests.swift` — deterministic fake state and fault-script tests.
- `Tests/LumiSyncKeyboardProbeTests/BoundedProcessTests.swift` — timeout, signal, process group, descendant, and cleanup tests.
- `Tests/LumiSyncKeyboardProbeTests/SafetySupervisorTests.swift` — in-process supervisor state-machine tests using injected process runners.
- `Tests/LumiSyncKeyboardProbeProcessTests/ProcessTestSupport.swift` — binary discovery, temporary fake state, bounded outer timeout, PID ownership, and journal assertions.
- `Tests/LumiSyncKeyboardProbeProcessTests/ThreeProcessRecoveryTests.swift` — real controller/supervisor/writer process topology and fault-injection tests.

### Icon track

- `design/lumisync-app-icon.png` — approved 1024×1024 transparent-corner master asset.
- `Scripts/build-app-icon.sh` — deterministic `.iconset` and `.icns` generation from the master.
- `Scripts/verify-app-icon.py` — PNG dimension/alpha sampling and `.icns` representation verification using standard-library parsing plus `iconutil` extraction.
- `Packaging/LumiSync/Resources/LumiSync.icns` — generated committed product icon.
- `Tests/Packaging/IconFixtureTests.swift` — invokes the verifier against repository assets and a generated opaque-corner negative fixture.

### D1 bundle track

- `Scripts/build-unsigned-release-app.sh` — clean release build and deterministic release-shaped bundle assembly without signing.
- `Scripts/verify-release-bundle.py` — bundle structure, version, resource, nested executable, Mach-O dependency, path, permission, and manifest validation.
- `Packaging/LumiSync/NestedCode.json` — expected nested executable paths, product names, bundle identifiers, and roles.
- `Tests/Packaging/ReleaseBundleFixtureTests.swift` — validates manifest parsing and negative bundle fixtures without signing credentials.
- `Scripts/package-local-app.sh` — delegates common assembly to the unsigned release builder, then adds local-only ad-hoc signing and Cask output.
- `Scripts/package-release.sh` — consumes a verified D1 bundle and retains credential/sign/notarization gates; D2 signing logic remains a later task.
- `.github/workflows/ci.yml` — runs unit/process tests, icon verification, and D1 structural verification with outer timeouts.

### Gate documentation

- `docs/feasibility/keyboard-backlight.md` — records H1 evidence and states that real writes remain blocked.
- `docs/release/homebrew.md` — records D1 output semantics and retains D2/D3 credential/publication gates.

---

## Parallel Ownership Rules

- H1 owns `Package.swift` first. Icon and D1 workers must not edit `Package.swift` until Task 1 lands.
- Icon owns `design/lumisync-app-icon.png`, `Scripts/build-app-icon.sh`, `Scripts/verify-app-icon.py`, and `Packaging/LumiSync/Resources/LumiSync.icns`.
- D1 owns release bundle scripts and `Packaging/LumiSync/NestedCode.json`; it consumes, but does not regenerate, the icon.
- CI is modified only in the final convergence task after all three tracks merge.
- `Apps/LumiSyncApp/LumiSyncApp.swift`, `Sources/LumiSyncKeyboardProbe/KeyboardBacklightCommand.swift`, and the CoreBrightness write path are protected files for this plan: tests may read/assert their behavior, but implementation tasks must not make real writes reachable.

---

### Task 1: H1 Safety Protocol and Executable Targets

**Files:**
- Create: `Sources/LumiSyncKeyboardProbe/SafetyProtocol.swift`
- Create: `Tests/LumiSyncKeyboardProbeTests/SafetyProtocolTests.swift`
- Modify: `Package.swift:7-41`

**Interfaces:**
- Produces: `public struct BacklightRequestID: RawRepresentable, Codable, Hashable, Sendable` with a non-empty, maximum-64-byte UTF-8 raw value.
- Produces: `public struct NormalizedBacklightValue: RawRepresentable, Codable, Equatable, Sendable` whose throwing initializer accepts only finite `0.0...1.0` values.
- Produces: `public enum BacklightOperation: Codable, Equatable, Sendable { case read; case set(NormalizedBacklightValue); case restore(NormalizedBacklightValue) }`.
- Produces: `public struct BacklightDeadline: Codable, Equatable, Sendable { public let remainingNanoseconds: UInt64 }`, rejecting zero and values above 30 seconds.
- Produces: `public struct BacklightRequest: Codable, Equatable, Sendable` containing protocol version `1`, request ID, operation, and deadline.
- Produces: `public enum BacklightFailure: Codable, Equatable, Sendable` with stable cases `rejected`, `timedOut(stage:)`, `writerFailed`, `readbackMismatch`, `restorationFailed`, `restorationUncertain`, and `protocolViolation`.
- Produces: `public enum BacklightOperationResult: Codable, Equatable, Sendable` with cases `success(readback:)` and `failure(primary:restoration:)`.
- Produces: `public enum RestorationOutcome: Codable, Equatable, Sendable { case notRequired; case verified(NormalizedBacklightValue); case failed; case uncertain }`.
- Produces executable targets `LumiSyncBacklightWriterCLI`, `LumiSyncBacklightSupervisorCLI`, and `LumiSyncBacklightControllerCLI`, each initially linked to `LumiSyncKeyboardProbe` with placeholder `main.swift` that exits with `EX_UNAVAILABLE` and never touches CoreBrightness.

- [ ] **Step 1: Write failing normalized-value and request-ID tests**

```swift
func testNormalizedBacklightValueRejectsNonFiniteAndOutOfRangeValues() {
    for value in [Double.nan, .infinity, -0.01, 1.01] {
        XCTAssertThrowsError(try NormalizedBacklightValue(value))
    }
    XCTAssertEqual(try NormalizedBacklightValue(0.5).rawValue, 0.5)
}

func testRequestIDIsNonEmptyAndLengthBounded() {
    XCTAssertThrowsError(try BacklightRequestID(rawValue: ""))
    XCTAssertNoThrow(try BacklightRequestID(rawValue: String(repeating: "a", count: 64)))
    XCTAssertThrowsError(try BacklightRequestID(rawValue: String(repeating: "a", count: 65)))
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
swift test --filter SafetyProtocolTests
```

Expected: compile failure because `NormalizedBacklightValue` and `BacklightRequestID` do not exist.

- [ ] **Step 3: Implement the validated scalar and request types**

Use throwing initializers, `Double.isFinite`, closed-range validation, UTF-8 byte counts, protocol version `1`, and a 30-second maximum deadline. Do not add raw keyboard IDs, selectors, executable paths, or library paths to any request type.

- [ ] **Step 4: Add failing Codable round-trip and unknown-version tests**

```swift
func testRequestRoundTripsThroughJSON() throws {
    let request = BacklightRequest(
        requestID: try BacklightRequestID(rawValue: "req-1"),
        operation: .set(try NormalizedBacklightValue(0.5)),
        deadline: try BacklightDeadline(remainingNanoseconds: 2_000_000_000)
    )
    XCTAssertEqual(try JSONDecoder().decode(
        BacklightRequest.self,
        from: JSONEncoder().encode(request)
    ), request)
}

func testDecoderRejectsUnknownProtocolVersion() {
    let json = Data(#"{"version":2,"requestID":"req-1","operation":{"read":{}},"deadline":{"remainingNanoseconds":1000000}}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(BacklightRequest.self, from: json))
}
```

Expected RED: unknown version currently decodes or encoded representation is incomplete.

- [ ] **Step 5: Implement explicit Codable validation and result precedence**

Add custom decoding that rejects versions other than `1`. Add:

```swift
public static func resolvedFailure(
    primary: BacklightFailure?,
    restoration: RestorationOutcome
) -> BacklightOperationResult
```

with exact precedence: `.failed` maps to `.restorationFailed`, `.uncertain` maps to `.restorationUncertain`, otherwise retain the primary failure, and only return success when a verified readback is provided by the caller.

- [ ] **Step 6: Add the three placeholder executable targets**

Add products and targets named:

```swift
.executable(name: "lumisync-backlight-writer", targets: ["LumiSyncBacklightWriterCLI"])
.executable(name: "lumisync-backlight-supervisor", targets: ["LumiSyncBacklightSupervisorCLI"])
.executable(name: "lumisync-backlight-controller", targets: ["LumiSyncBacklightControllerCLI"])
```

Each placeholder `main.swift` writes `H1 executable not configured` to stderr and calls `exit(EX_UNAVAILABLE)`. It must not instantiate `CoreBrightnessKeyboardBacklightBackend`.

- [ ] **Step 7: Run protocol tests and all existing write-block tests**

Run:

```bash
swift test --filter SafetyProtocolTests
swift test --filter KeyboardBacklightSafetyTests/testWriteCommandRemainsBlockedEvenWithBothExplicitFlags
swift test --filter KeyboardBacklightSafetyTests/testReadOnlyProbeNeverWrites
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/LumiSyncKeyboardProbe/SafetyProtocol.swift \
  Sources/LumiSyncBacklightWriterCLI/main.swift \
  Sources/LumiSyncBacklightSupervisorCLI/main.swift \
  Sources/LumiSyncBacklightControllerCLI/main.swift \
  Tests/LumiSyncKeyboardProbeTests/SafetyProtocolTests.swift
git commit -m "feat: define bounded backlight safety protocol"
```

---

### Task 2: Qualification Identity and Build Invalidation

**Files:**
- Create: `Sources/LumiSyncKeyboardProbe/Qualification.swift`
- Create: `Tests/LumiSyncKeyboardProbeTests/QualificationTests.swift`

**Interfaces:**
- Consumes: `BacklightFailure.rejected`.
- Produces: `public struct BacklightQualificationIdentity: Codable, Equatable, Sendable` with model identifier, architecture, macOS version, macOS build, framework-present flag, class-present flag, and selector signatures.
- Produces: `public struct ObjectiveCSelectorSignature: Codable, Equatable, Sendable { name: String; typeEncoding: String }`.
- Produces: `public enum BacklightQualificationState: Codable, Equatable, Sendable { case unqualified(reason: String); case qualified(BacklightQualificationIdentity) }`.
- Produces: `public struct BacklightQualificationPolicy { public func evaluate(saved:current:) -> BacklightQualificationState }`.

- [ ] **Step 1: Write failing exact-build tests**

```swift
func testQualificationRequiresExactOSBuildAndSelectorSignatures() {
    let saved = fixture(build: "24G90", setterEncoding: "B@:fQ")
    XCTAssertEqual(
        BacklightQualificationPolicy().evaluate(saved: saved, current: saved),
        .qualified(saved)
    )
    XCTAssertNotEqual(
        BacklightQualificationPolicy().evaluate(
            saved: saved,
            current: fixture(build: "24G91", setterEncoding: "B@:fQ")
        ),
        .qualified(saved)
    )
    XCTAssertNotEqual(
        BacklightQualificationPolicy().evaluate(
            saved: saved,
            current: fixture(build: "24G90", setterEncoding: "v@:fQ")
        ),
        .qualified(saved)
    )
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter QualificationTests`

Expected: compile failure because qualification types do not exist.

- [ ] **Step 3: Implement exact identity matching**

Require exact equality for every identity field. Empty selector names/encodings, missing framework/class, architecture other than `arm64`, or an empty OS build produce `.unqualified`. This task records policy only; it does not persist qualification or enable a write command.

- [ ] **Step 4: Add a CoreBrightness signature inspection seam without writing**

Extend `CoreBrightnessKeyboardBacklightBackend` with a read-only static inspection method that returns selector names and `method_getTypeEncoding` strings. Add no call to `setBrightness` and do not change CLI write parsing.

Test through an injected Objective-C metadata provider so CI does not require a particular private-framework signature.

- [ ] **Step 5: Run qualification and write-block tests**

```bash
swift test --filter QualificationTests
swift test --filter KeyboardBacklightSafetyTests/testWriteCommandRemainsBlockedEvenWithBothExplicitFlags
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumiSyncKeyboardProbe/Qualification.swift \
  Sources/LumiSyncKeyboardProbe/CoreBrightnessKeyboardBacklightBackend.swift \
  Tests/LumiSyncKeyboardProbeTests/QualificationTests.swift
git commit -m "feat: invalidate backlight qualification by build"
```

---

### Task 3: Length-Bounded Framed Messages

**Files:**
- Create: `Sources/LumiSyncKeyboardProbe/FramedJSON.swift`
- Create: `Tests/LumiSyncKeyboardProbeTests/FramedJSONTests.swift`

**Interfaces:**
- Consumes: Codable request/result types from Task 1.
- Produces: `public struct FramedJSONCodec: Sendable` with `maximumPayloadBytes = 16_384`.
- Produces: `public func encode<T: Encodable>(_ value: T) throws -> Data` using a four-byte big-endian length prefix.
- Produces: `public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T` requiring exactly one complete frame and rejecting trailing bytes.
- Produces: `public enum FramedJSONError: Error, Equatable` with `empty`, `truncatedHeader`, `oversized`, `truncatedPayload`, and `trailingBytes`.

- [ ] **Step 1: Write failing framing tests**

```swift
func testCodecRoundTripsExactlyOneRequest() throws {
    let request = makeReadRequest()
    let frame = try FramedJSONCodec().encode(request)
    XCTAssertEqual(try FramedJSONCodec().decode(BacklightRequest.self, from: frame), request)
}

func testCodecRejectsOversizedAndTrailingPayloads() throws {
    var oversized = Data([0, 0, 64, 1])
    oversized.append(Data(repeating: 0, count: 16_385))
    XCTAssertThrowsError(try FramedJSONCodec().decode(BacklightRequest.self, from: oversized))

    var valid = try FramedJSONCodec().encode(makeReadRequest())
    valid.append(0)
    XCTAssertThrowsError(try FramedJSONCodec().decode(BacklightRequest.self, from: valid))
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter FramedJSONTests`

Expected: compile failure because `FramedJSONCodec` does not exist.

- [ ] **Step 3: Implement exact single-frame decoding**

Use explicit byte shifts for the unsigned big-endian length. Reject payloads before JSON decoding if declared or actual sizes exceed the limit. Never stream until EOF without a size bound.

- [ ] **Step 4: Run focused and protocol tests**

```bash
swift test --filter FramedJSONTests
swift test --filter SafetyProtocolTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LumiSyncKeyboardProbe/FramedJSON.swift \
  Tests/LumiSyncKeyboardProbeTests/FramedJSONTests.swift
git commit -m "feat: add bounded process message framing"
```

---

### Task 4: Cross-Process Fake Backlight Device

**Files:**
- Create: `Sources/LumiSyncKeyboardProbe/FakeBacklightDevice.swift`
- Create: `Tests/LumiSyncKeyboardProbeTests/FakeBacklightDeviceTests.swift`

**Interfaces:**
- Consumes: `NormalizedBacklightValue`, `BacklightOperation`.
- Produces: `public struct FakeBacklightDeviceConfiguration: Codable, Equatable, Sendable` with initial value and ordered fault actions.
- Produces: `public enum FakeBacklightFaultAction: Codable, Equatable, Sendable` cases `returnValue`, `sleepNanoseconds`, `exit(code:)`, `raise(signal:)`, `malformedOutput`, `forkSleepingChild`, and `attemptSetsid`.
- Produces: `public struct FakeBacklightJournalEntry: Codable, Equatable, Sendable` containing sequence number, request ID, process role, operation category, value, and PID; no arbitrary strings from the environment.
- Produces: `public final class FileBackedFakeBacklightDevice` initialized with a test-created directory containing `state.json`, `faults.json`, and `journal.jsonl`.

- [ ] **Step 1: Write failing atomic-state tests**

```swift
func testWriteAndReadPersistAcrossDeviceInstances() throws {
    let directory = try makeTemporaryFakeDevice(initial: 0.37)
    try FileBackedFakeBacklightDevice(directory: directory).write(
        try NormalizedBacklightValue(0.5), requestID: requestID
    )
    XCTAssertEqual(
        try FileBackedFakeBacklightDevice(directory: directory).read(requestID: requestID),
        try NormalizedBacklightValue(0.5)
    )
}

func testFaultActionsAreConsumedInOrder() throws {
    let directory = try makeTemporaryFakeDevice(
        initial: 0.37,
        faults: [.sleepNanoseconds(1), .returnValue(try NormalizedBacklightValue(0.25))]
    )
    XCTAssertEqual(try consumeFault(directory), .sleepNanoseconds(1))
    XCTAssertEqual(try consumeFault(directory), .returnValue(try NormalizedBacklightValue(0.25)))
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter FakeBacklightDeviceTests`

Expected: compile failure because the fake device does not exist.

- [ ] **Step 3: Implement locked atomic state and bounded journal records**

Use `flock` on a lock file owned by the test directory, write replacement JSON to a sibling temporary file, call `fsync`, and rename atomically. Journal sequence allocation occurs under the same lock. Reject symlinks and require the supplied directory and files to be owned by the current user.

- [ ] **Step 4: Add failing tests for symlink rejection and invalid state**

Verify that a symlinked state file, non-finite JSON value, out-of-range value, oversized fault file, and unknown fault case all throw before mutation.

- [ ] **Step 5: Implement validation and run tests**

```bash
swift test --filter FakeBacklightDeviceTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumiSyncKeyboardProbe/FakeBacklightDevice.swift \
  Tests/LumiSyncKeyboardProbeTests/FakeBacklightDeviceTests.swift
git commit -m "test: add cross-process fake backlight device"
```

---

### Task 5: Bounded Owned-Process Runner

**Files:**
- Create: `Sources/LumiSyncKeyboardProbe/BoundedProcess.swift`
- Create: `Tests/LumiSyncKeyboardProbeTests/BoundedProcessTests.swift`

**Interfaces:**
- Consumes: framed message data from Task 3.
- Produces: `public struct OwnedProcessRequest: Sendable` containing a fixed executable URL supplied by the trusted parent, fixed arguments, stdin frame, and monotonic timeout.
- Produces: `public struct OwnedProcessResult: Equatable, Sendable` containing termination reason/status, bounded stdout/stderr, root PID, and whether cleanup was verified.
- Produces: `public protocol OwnedProcessRunning: Sendable { func run(_ request: OwnedProcessRequest) async -> OwnedProcessResult }`.
- Produces: `public actor BoundedOwnedProcessRunner: OwnedProcessRunning`.

- [ ] **Step 1: Write failing exit and timeout tests using `/bin/sh` only as a test fixture**

```swift
func testRunnerCapturesBoundedOutputAndExitStatus() async {
    let result = await runner.run(fixture(command: "printf ok; exit 7", timeout: .seconds(1)))
    XCTAssertEqual(result.exitStatus, 7)
    XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "ok")
    XCTAssertTrue(result.cleanupVerified)
}

func testRunnerKillsProcessGroupAtMonotonicDeadline() async {
    let result = await runner.run(fixture(command: "sleep 30", timeout: .milliseconds(100)))
    XCTAssertEqual(result.termination, .timedOut)
    XCTAssertTrue(result.cleanupVerified)
}
```

Production controller/supervisor code must not accept `/bin/sh` or shell commands; these tests exercise only the generic owned-process utility.

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter BoundedProcessTests`

Expected: compile failure because the runner does not exist.

- [ ] **Step 3: Implement launch and deadline containment**

Use `posix_spawn` with a new owned process group, pipes created before spawn, close-on-exec descriptors, a `ContinuousClock` deadline, and bounded 64 KiB stdout/stderr collectors. On timeout, send `SIGTERM` to the owned group, wait at most 100 ms, then send `SIGKILL`; reap the root process with `waitpid`.

- [ ] **Step 4: Add failing descendant and `setsid` escape tests**

Create a test fixture that spawns a sleeping child and another that attempts `setsid`. Record fixture PIDs in a test-owned pipe or file. Assert every recorded PID is absent after runner completion. The runner must reject success when owned descendants survive or when process topology cannot be verified.

- [ ] **Step 5: Implement owned-descendant verification**

Use macOS `proc_listchildpids`/`proc_pidinfo` only for the root PID and descendants created by the test. Snapshot descendants while the root is alive, kill known descendants during cleanup, and verify `kill(pid, 0)` returns `ESRCH`. Never scan or signal unrelated processes.

- [ ] **Step 6: Run process-runner tests repeatedly**

```bash
for i in 1 2 3 4 5; do
  swift test --filter BoundedProcessTests || exit 1
done
```

Expected: five PASS runs, no surviving fixture process.

- [ ] **Step 7: Commit**

```bash
git add Sources/LumiSyncKeyboardProbe/BoundedProcess.swift \
  Tests/LumiSyncKeyboardProbeTests/BoundedProcessTests.swift
git commit -m "feat: contain bounded backlight worker processes"
```

---

### Task 6: One-Shot Fake Writer Executable

**Files:**
- Create: `Sources/LumiSyncKeyboardProbe/FakeWriterService.swift`
- Create: `Tests/LumiSyncKeyboardProbeTests/FakeWriterServiceTests.swift`
- Replace: `Sources/LumiSyncBacklightWriterCLI/main.swift`

**Interfaces:**
- Consumes: `BacklightRequest`, `FramedJSONCodec`, `FileBackedFakeBacklightDevice`.
- Produces: `public struct FakeWriterService { public func execute(_ request: BacklightRequest, deviceDirectory: URL) -> BacklightOperationResult }`.
- Writer CLI consumes exactly one framed request on stdin and a trusted `LUMISYNC_H1_FAKE_DEVICE_DIR` environment value supplied by the supervisor test harness.
- Writer CLI emits exactly one framed `BacklightOperationResult` on stdout and bounded diagnostics on stderr.

- [ ] **Step 1: Write failing read/write/readback service tests**

```swift
func testSetWritesAndReturnsVerifiedReadback() throws {
    let directory = try makeTemporaryFakeDevice(initial: 0.37)
    let result = FakeWriterService().execute(
        makeRequest(operation: .set(try NormalizedBacklightValue(0.5))),
        deviceDirectory: directory
    )
    XCTAssertEqual(result, .success(readback: try NormalizedBacklightValue(0.5)))
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter FakeWriterServiceTests`

Expected: compile failure because `FakeWriterService` does not exist.

- [ ] **Step 3: Implement one operation and readback**

For `.set` and `.restore`, write then read the fake state and compare with tolerance `0.01`. For `.read`, return the read value. Apply one configured fake fault at the exact requested stage. Return structured failure; do not throw raw backend errors across the process boundary.

- [ ] **Step 4: Add CLI subprocess smoke test**

Build `lumisync-backlight-writer`, send one framed fake read request, decode exactly one result, and assert the process exits `0`. Add negative cases for empty input, oversized input, trailing bytes, missing fake directory, malformed output fault, and unknown protocol version.

- [ ] **Step 5: Run writer and write-block tests**

```bash
swift test --filter FakeWriterServiceTests
swift test --filter KeyboardBacklightSafetyTests/testWriteCommandRemainsBlockedEvenWithBothExplicitFlags
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LumiSyncKeyboardProbe/FakeWriterService.swift \
  Sources/LumiSyncBacklightWriterCLI/main.swift \
  Tests/LumiSyncKeyboardProbeTests/FakeWriterServiceTests.swift
git commit -m "feat: add one-shot fake backlight writer"
```

---

### Task 7: Recovery Supervisor State Machine

**Files:**
- Create: `Sources/LumiSyncKeyboardProbe/SafetySupervisor.swift`
- Create: `Tests/LumiSyncKeyboardProbeTests/SafetySupervisorTests.swift`

**Interfaces:**
- Consumes: `OwnedProcessRunning`, writer executable URL, framed protocol, and normalized request/result types.
- Produces: `public struct BacklightSupervisorConfiguration: Sendable` containing fixed writer executable URL, fake device directory, readback tolerance `0.01`, and per-stage maximum durations.
- Produces: `public actor BacklightSafetySupervisor { public func execute(_ request: BacklightRequest) async -> BacklightOperationResult }`.
- Produces: `public enum BacklightStage: String, Codable, Sendable` values `captureOriginal`, `write`, `writeReadback`, `restore`, and `restoreReadback`.

- [ ] **Step 1: Write failing normal-recovery test with a scripted process runner**

```swift
func testSupervisorCapturesOriginalBeforeMutationAndRestoresAfterSuccess() async throws {
    let runner = ScriptedOwnedProcessRunner(results: [
        writerSuccess(0.37),
        writerSuccess(0.5),
        writerSuccess(0.37),
    ])
    let result = await makeSupervisor(runner: runner).execute(makeSetRequest(0.5))
    XCTAssertEqual(result, .success(readback: try NormalizedBacklightValue(0.5)))
    XCTAssertEqual(runner.operations, [.read, .set(0.5), .restore(0.37)])
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter SafetySupervisorTests`

Expected: compile failure because the supervisor does not exist.

- [ ] **Step 3: Implement capture, mutation, restoration, and verified result**

The supervisor must store original brightness in actor state before launching a mutation writer. It always attempts restoration after a mutation attempt, including write failure, readback mismatch, cancellation, timeout, or malformed writer result. A read-only operation requires no restoration.

- [ ] **Step 4: Add failure-precedence table tests**

Cover this exact table:

| Primary | Restore | Expected |
|---|---|---|
| success | verified | success |
| timed out | verified | timed out + verified restoration |
| writer failed | verified | writer failed + verified restoration |
| any | failed | restoration failed |
| any | uncertain | restoration uncertain |

Also test invalid original brightness prevents mutation launch.

- [ ] **Step 5: Add stage-budget tests**

Inject a manual clock or scripted runner timestamps. Assert no child request receives more remaining time than the parent deadline and no stage runs after the overall deadline. Cancellation still invokes restoration with its reserved deadline budget.

- [ ] **Step 6: Run supervisor tests**

```bash
swift test --filter SafetySupervisorTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LumiSyncKeyboardProbe/SafetySupervisor.swift \
  Tests/LumiSyncKeyboardProbeTests/SafetySupervisorTests.swift
git commit -m "feat: add independent recovery supervisor"
```

---

### Task 8: Supervisor Executable and Controller Serialization

**Files:**
- Create: `Sources/LumiSyncKeyboardProbe/SafetyController.swift`
- Create: `Tests/LumiSyncKeyboardProbeTests/SafetyControllerTests.swift`
- Replace: `Sources/LumiSyncBacklightSupervisorCLI/main.swift`
- Replace: `Sources/LumiSyncBacklightControllerCLI/main.swift`

**Interfaces:**
- Consumes: supervisor state machine, bounded process runner, framed protocol.
- Produces: `public actor BacklightSafetyController { public func submit(_ request: BacklightRequest) async -> BacklightOperationResult }`.
- Controller rule: at most one active request; a materially identical pending set request shares the active result; a different concurrent request is rejected as `busy` rather than racing.
- Supervisor CLI accepts one framed App-facing request and launches only the compiled writer executable path resolved relative to its own executable directory.
- Controller CLI accepts one framed request and launches only the sibling supervisor executable.

- [ ] **Step 1: Write failing controller serialization tests**

```swift
func testIdenticalConcurrentRequestSharesOneSupervisorCall() async throws {
    let supervisor = BlockingSupervisor()
    let controller = BacklightSafetyController(supervisor: supervisor)
    async let first = controller.submit(makeSetRequest(0.5, id: "a"))
    async let second = controller.submit(makeSetRequest(0.5, id: "b"))
    await supervisor.release()
    _ = await (first, second)
    XCTAssertEqual(await supervisor.callCount, 1)
}

func testDifferentConcurrentRequestIsRejectedBusy() async {
    // Start 0.5, hold it, then submit 0.8 and assert stable rejected/busy result.
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter SafetyControllerTests`

Expected: compile failure because the controller does not exist.

- [ ] **Step 3: Implement actor serialization and duplicate sharing**

Normalize equality using exact `NormalizedBacklightValue` equality for H1. Do not accept client-provided executable paths, fake directories, keyboard IDs, selectors, or shell commands. Production code derives sibling executable paths from a trusted bundle layout.

- [ ] **Step 4: Implement supervisor and controller CLIs**

Both CLIs decode exactly one frame, enforce their deadline, emit exactly one result frame, and exit. The fake device directory is accepted only in an H1 compile/runtime mode and is never part of `BacklightRequest`.

- [ ] **Step 5: Add full normal-chain subprocess smoke test**

Build all three products, initialize fake brightness `0.37`, submit set `0.5` to controller, and assert:

- result reports requested readback `0.5`;
- final fake state is restored to `0.37`;
- journal order is read original → set 0.5/readback → restore 0.37/readback;
- three distinct process roles appear; and
- every recorded PID has exited.

- [ ] **Step 6: Run controller tests and smoke chain**

```bash
swift test --filter SafetyControllerTests
swift test --filter ThreeProcessRecoveryTests/testNormalChainRestoresOriginalValue
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LumiSyncKeyboardProbe/SafetyController.swift \
  Sources/LumiSyncBacklightSupervisorCLI/main.swift \
  Sources/LumiSyncBacklightControllerCLI/main.swift \
  Tests/LumiSyncKeyboardProbeTests/SafetyControllerTests.swift \
  Tests/LumiSyncKeyboardProbeProcessTests/ProcessTestSupport.swift \
  Tests/LumiSyncKeyboardProbeProcessTests/ThreeProcessRecoveryTests.swift \
  Package.swift
git commit -m "feat: connect three-process backlight safety chain"
```

---

### Task 9: H1 Signal and Stage-Timeout Fault Injection

**Files:**
- Modify: `Tests/LumiSyncKeyboardProbeProcessTests/ThreeProcessRecoveryTests.swift`
- Modify: `Tests/LumiSyncKeyboardProbeProcessTests/ProcessTestSupport.swift`
- Modify: `Sources/LumiSyncKeyboardProbe/FakeBacklightDevice.swift`

**Interfaces:**
- Consumes: complete process chain from Task 8.
- Produces: deterministic process test helpers `runScenario(_:outerTimeout:)`, `waitForJournalEvent(_:)`, `signalOwnedRole(_:_:)`, and `assertNoOwnedProcessesRemain()`.

- [ ] **Step 1: Add failing writer-signal matrix test**

```swift
func testWriterSignalsRestoreOriginalValue() throws {
    for signal in [SIGINT, SIGTERM, SIGABRT, SIGKILL] {
        let scenario = try startScenario(pausedAt: .writerAfterMutation)
        try scenario.signalOwnedRole(.writer, signal)
        let result = try scenario.finish()
        XCTAssertEqual(try scenario.currentValue(), 0.37, "signal=\(signal)")
        XCTAssertTrue(result.restoration.isVerified, "signal=\(signal)")
        try scenario.assertNoOwnedProcessesRemain()
    }
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter ThreeProcessRecoveryTests/testWriterSignalsRestoreOriginalValue`

Expected: FAIL because pause/signal scenario control is missing or restoration is incomplete.

- [ ] **Step 3: Implement journal barriers and signal control**

Use fake-device journal events as condition-based barriers; do not use arbitrary sleeps to decide when mutation occurred. Signal only PIDs recorded for the scenario. Preserve the supervisor process while killing writer/controller roles.

- [ ] **Step 4: Add controller-signal matrix test**

For `SIGINT`, `SIGTERM`, `SIGABRT`, and `SIGKILL`, kill the controller after mutation is journaled. Assert the independently running supervisor restores and verifies original brightness, then exits and leaves no owned processes.

- [ ] **Step 5: Add failing stage-timeout matrix**

Test hangs at `captureOriginal`, `write`, `writeReadback`, `restore`, and `restoreReadback`. Expected outcomes:

- capture-original timeout: no mutation occurred;
- write/write-readback timeout: restoration attempted and verified;
- restore timeout: restoration uncertain or failed, never success;
- restore-readback timeout: restoration uncertain, never success;
- every scenario exits within a 5-second outer timeout and leaves no owned process.

- [ ] **Step 6: Implement deterministic fault stages and deadline assertions**

Fault actions must be tied to operation/stage categories, not global wall-clock sleeps. Every child gets a remaining duration less than or equal to its parent budget.

- [ ] **Step 7: Run fault matrix twice**

```bash
for i in 1 2; do
  swift test --filter ThreeProcessRecoveryTests || exit 1
done
```

Expected: both full process-test runs PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/LumiSyncKeyboardProbe/FakeBacklightDevice.swift \
  Tests/LumiSyncKeyboardProbeProcessTests/ProcessTestSupport.swift \
  Tests/LumiSyncKeyboardProbeProcessTests/ThreeProcessRecoveryTests.swift
git commit -m "test: prove signal and timeout recovery containment"
```

---

### Task 10: H1 Protocol Abuse and Process-Escape Tests

**Files:**
- Modify: `Tests/LumiSyncKeyboardProbeProcessTests/ThreeProcessRecoveryTests.swift`
- Modify: `Sources/LumiSyncKeyboardProbe/BoundedProcess.swift`
- Modify: `Sources/LumiSyncKeyboardProbe/FakeWriterService.swift`

**Interfaces:**
- Consumes: H1 chain and fake fault actions.
- Produces: no new production public interface; completes H1 adversarial evidence.

- [ ] **Step 1: Add failing malformed-input matrix**

Send empty input, truncated header, oversized frame, truncated JSON, unknown version, trailing bytes, two frames, unknown operation, non-finite brightness encoding, and extra writer stdout. Assert stable protocol failure and no mutation unless the journal proves original capture and subsequent verified restoration.

- [ ] **Step 2: Run malformed-input tests and verify RED**

Run: `swift test --filter ThreeProcessRecoveryTests/testMalformedProtocolIsRejectedWithoutLeakingProcesses`

Expected: at least one malformed case is accepted or cleanup evidence is missing.

- [ ] **Step 3: Tighten exact-frame and exact-output enforcement**

Require exactly one frame from each child, no trailing bytes, bounded stderr, and known result version/case. Unknown values map to protocol violation and trigger restoration whenever mutation may have occurred.

- [ ] **Step 4: Add failing escape-attempt tests**

Run fake writer actions for forked sleeping child and `setsid` attempt. Assert the scenario cannot report success, every known PID exits, and final brightness is restored or the result is restoration uncertain. A surviving descendant is a test failure even when brightness is restored.

- [ ] **Step 5: Implement containment corrections**

Close inherited descriptors, verify process group ownership, track descendants while the root is alive, and kill/reap every owned known descendant on completion. Never broaden signaling beyond scenario-owned PIDs/process group.

- [ ] **Step 6: Run all H1 tests and real-write guards**

```bash
swift test --filter LumiSyncKeyboardProbeTests
swift test --filter LumiSyncKeyboardProbeProcessTests
swift test --filter KeyboardBacklightSafetyTests/testWriteCommandRemainsBlockedEvenWithBothExplicitFlags
```

Expected: PASS and no process survives.

- [ ] **Step 7: Commit**

```bash
git add Sources/LumiSyncKeyboardProbe/BoundedProcess.swift \
  Sources/LumiSyncKeyboardProbe/FakeWriterService.swift \
  Tests/LumiSyncKeyboardProbeProcessTests/ThreeProcessRecoveryTests.swift
git commit -m "test: reject backlight protocol and process escapes"
```

---

### Task 11: Transparent Squircle Icon Verification

**Files:**
- Create: `Scripts/verify-app-icon.py`
- Create: `Tests/Packaging/IconFixtureTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Produces: CLI `python3 Scripts/verify-app-icon.py --master <png> --icns <icns>` with exit `0` only when all checks pass.
- Verifier checks PNG signature, IHDR width/height `1024`, color type with alpha, four corner alpha values `0`, sampled outer-corner regions fully transparent, center non-transparent, and extracted `.icns` representations `16, 32, 64, 128, 256, 512, 1024`.
- Produces test target `LumiSyncPackagingTests` with repository root passed through `#filePath` traversal.

- [ ] **Step 1: Write failing negative-fixture test**

```swift
func testVerifierRejectsOpaqueSquareCanvas() throws {
    let fixture = try makeOpaqueRGBAFixture(width: 1024, height: 1024)
    let result = try runVerifier(master: fixture, icns: repositoryICNS)
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.stderr.contains("transparent outer corners"))
}
```

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter IconFixtureTests/testVerifierRejectsOpaqueSquareCanvas`

Expected: compile failure or missing verifier.

- [ ] **Step 3: Implement standard-library PNG alpha verification**

Parse PNG chunks, concatenate/decompress IDAT with Python `zlib`, apply PNG filters for 8-bit RGBA rows, and inspect alpha. Reject interlaced, palette-only, RGB-without-alpha, malformed, or truncated files with explicit messages. Do not depend on Pillow or network-installed packages.

- [ ] **Step 4: Implement `.icns` extraction verification**

Copy the `.icns` to a temporary directory, run `iconutil -c iconset`, inspect PNG IHDR dimensions, and require all representation sizes. Ensure temporary files are removed.

- [ ] **Step 5: Run the negative fixture against the current icon**

Run:

```bash
python3 Scripts/verify-app-icon.py \
  --master design/lumisync-app-icon.png \
  --icns Packaging/LumiSync/Resources/LumiSync.icns
```

Expected at this stage: FAIL with transparent-corner diagnostics, proving the existing defect is detected.

- [ ] **Step 6: Commit the verifier and failing regression test only**

```bash
git add Package.swift Scripts/verify-app-icon.py Tests/Packaging/IconFixtureTests.swift
git commit -m "test: detect opaque app icon corners"
```

---

### Task 12: Generate the Native macOS Squircle Icon

**Files:**
- Create: `Scripts/build-app-icon.sh`
- Replace: `design/lumisync-app-icon.png`
- Replace: `Packaging/LumiSync/Resources/LumiSync.icns`
- Modify: `Tests/Packaging/IconFixtureTests.swift`

**Interfaces:**
- Consumes: verifier from Task 11.
- Produces: deterministic iconset generation at required dimensions and `LumiSync.icns`.

- [ ] **Step 1: Create the revised 1024×1024 master**

Generate or edit the approved concept with these exact invariants:

- transparent pixels outside one centered macOS-style squircle;
- no full-canvas rectangle or backing plate;
- blue display in the upper region;
- amber keyboard in the lower region;
- one blue-to-amber synchronization light connecting them;
- reduced keycap, frame, reflection, and border detail;
- no text or lightbulb;
- optical margin comparable to native macOS icons.

Save directly as RGBA PNG at `design/lumisync-app-icon.png`.

- [ ] **Step 2: Run the verifier and verify the master turns GREEN**

```bash
python3 Scripts/verify-app-icon.py \
  --master design/lumisync-app-icon.png \
  --icns Packaging/LumiSync/Resources/LumiSync.icns
```

Expected: master checks PASS; old `.icns` may still fail or mismatch before regeneration.

- [ ] **Step 3: Implement deterministic iconset generation**

`Scripts/build-app-icon.sh` must use `sips` to generate:

```text
icon_16x16.png
icon_16x16@2x.png
icon_32x32.png
icon_32x32@2x.png
icon_128x128.png
icon_128x128@2x.png
icon_256x256.png
icon_256x256@2x.png
icon_512x512.png
icon_512x512@2x.png
```

Then run `iconutil -c icns`, move the result to `Packaging/LumiSync/Resources/LumiSync.icns`, and invoke the verifier. The temporary iconset is removed on exit.

- [ ] **Step 4: Rebuild and run automated icon tests**

```bash
bash Scripts/build-app-icon.sh
swift test --filter IconFixtureTests
```

Expected: PASS.

- [ ] **Step 5: Build the local App and perform visual acceptance**

```bash
bash Scripts/package-local-app.sh
```

Install the local App only after checking the target path. Compare Finder and Launchpad at 16, 32, and 64 px against neighboring native macOS icons. Pass only if the outer silhouette is a squircle with transparent corners, apparent size is balanced, and the display/keyboard metaphor remains legible. This is a human/desktop visual gate; do not infer it solely from alpha tests.

- [ ] **Step 6: Commit**

```bash
git add Scripts/build-app-icon.sh design/lumisync-app-icon.png \
  Packaging/LumiSync/Resources/LumiSync.icns \
  Tests/Packaging/IconFixtureTests.swift
git commit -m "design: replace app icon with native squircle"
```

---

### Task 13: D1 Nested-Code Manifest and Bundle Verifier

**Files:**
- Create: `Packaging/LumiSync/NestedCode.json`
- Create: `Scripts/verify-release-bundle.py`
- Create: `Tests/Packaging/ReleaseBundleFixtureTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Produces manifest entries:

```json
{
  "version": 1,
  "executables": [
    {"path":"Contents/MacOS/LumiSync","product":"LumiSyncApp","role":"app"},
    {"path":"Contents/Helpers/lumisync-backlight-controller","product":"lumisync-backlight-controller","role":"controller"},
    {"path":"Contents/Helpers/lumisync-backlight-supervisor","product":"lumisync-backlight-supervisor","role":"supervisor"},
    {"path":"Contents/Helpers/lumisync-backlight-writer","product":"lumisync-backlight-writer","role":"writer"}
  ]
}
```

- Produces CLI `python3 Scripts/verify-release-bundle.py --app <path> --manifest <path> --version <version> --build-number <number>`.
- The verifier checks exact expected executable set, executable permissions, no group/world-writable code, Info.plist version values, icon/resource presence, localization bundle presence, Mach-O architecture `arm64`, and absence of dependency/rpath strings containing repository path, `.build`, `/Users/`, or `/private/tmp/`.

- [ ] **Step 1: Write failing manifest fixture tests**

Create a minimal temporary `.app` fixture with one missing helper, one unexpected executable, wrong version, and a fake dependency string containing `.build`. Assert each error is reported separately and validation exits nonzero.

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter ReleaseBundleFixtureTests`

Expected: compile failure or missing verifier.

- [ ] **Step 3: Implement strict manifest parsing and bundle checks**

Use Python standard library only. Reject duplicate paths/roles, path traversal, absolute paths, symlinks in executable locations, missing files, unexpected executable files under `Contents/MacOS` or `Contents/Helpers`, and writable code. Use `file`, `otool -L`, and `otool -l` for real Mach-O files; fixture mode may use explicit mock marker files created by tests.

- [ ] **Step 4: Run fixture tests**

```bash
swift test --filter ReleaseBundleFixtureTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Packaging/LumiSync/NestedCode.json \
  Scripts/verify-release-bundle.py Tests/Packaging/ReleaseBundleFixtureTests.swift
git commit -m "test: verify unsigned release bundle structure"
```

---

### Task 14: Reproducible Unsigned Release App Builder

**Files:**
- Create: `Scripts/build-unsigned-release-app.sh`
- Modify: `Scripts/package-local-app.sh`
- Modify: `Scripts/package-release.sh`
- Modify: `docs/release/homebrew.md`

**Interfaces:**
- Consumes: icon, nested-code manifest, release verifier, SwiftPM products.
- Produces: `build/unsigned-release/LumiSync.app` by default.
- Inputs: `VERSION` matching `^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$`, numeric `BUILD_NUMBER`, `CONFIGURATION=release`, optional clean `BUILD_DIR`.
- Output contains App executable, three H1 helper executables, localizations, icon, explicit Info.plist versions, and no signature.

- [ ] **Step 1: Write a failing end-to-end D1 test**

In `ReleaseBundleFixtureTests`, invoke the builder into a temporary output directory, then invoke the verifier. Assert the exact four executable paths and exact version/build number.

- [ ] **Step 2: Run and verify RED**

Run: `swift test --filter ReleaseBundleFixtureTests/testBuilderProducesVerifiedUnsignedBundle`

Expected: FAIL because the builder does not exist.

- [ ] **Step 3: Implement clean release building**

The script must:

```bash
swift build --package-path "$REPO_ROOT" --configuration release \
  --product LumiSyncApp \
  --product lumisync-backlight-controller \
  --product lumisync-backlight-supervisor \
  --product lumisync-backlight-writer
```

If SwiftPM does not accept multiple `--product` flags, invoke one explicit build per product. Resolve the bin path once, stage into a fresh temporary App, copy only manifest-listed executables, copy resources and localization bundle, set versions with `PlistBuddy`, set deterministic permissions, run the verifier, then atomically replace the output App. Do not call `codesign`.

- [ ] **Step 4: Refactor local packaging to consume D1 output**

`package-local-app.sh` calls the unsigned builder with local version inputs, copies the verified App to `build/local`, applies the existing ad-hoc signature, verifies it, and creates the local ZIP/Cask. Preserve the explicit warning that it is not Developer ID signed or notarized.

- [ ] **Step 5: Make release packaging require verified D1 input**

Before checking signing/notary prerequisites, `package-release.sh` invokes `verify-release-bundle.py` on `APP_PATH`. It must still fail honestly when Developer ID identity or notary credentials are absent. Do not implement D2 signing in this task.

- [ ] **Step 6: Run D1 and local-package verification**

```bash
VERSION=0.2.0-dev BUILD_NUMBER=2 bash Scripts/build-unsigned-release-app.sh
python3 Scripts/verify-release-bundle.py \
  --app build/unsigned-release/LumiSync.app \
  --manifest Packaging/LumiSync/NestedCode.json \
  --version 0.2.0-dev --build-number 2
bash Scripts/package-local-app.sh
codesign --verify --deep --strict build/local/LumiSync.app
```

Expected: all PASS. `bash Scripts/package-release.sh` must exit nonzero with explicit missing Developer ID/notary prerequisites in an uncredentialed environment.

- [ ] **Step 7: Document D1 semantics and later gates**

State that D1 is unsigned structure only; D2 must add inside-out Developer ID signing, Hardened Runtime, identity/requirement verification, notarization, stapling, and Gatekeeper assessment. D3 must replace the development Cask version and `sha256 :no_check` only after explicit publication authorization.

- [ ] **Step 8: Commit**

```bash
git add Scripts/build-unsigned-release-app.sh Scripts/package-local-app.sh \
  Scripts/package-release.sh docs/release/homebrew.md
git commit -m "build: assemble reproducible unsigned release app"
```

---

### Task 15: CI Convergence and H1 Gate Evidence

**Files:**
- Modify: `.github/workflows/ci.yml`
- Modify: `docs/feasibility/keyboard-backlight.md`
- Modify: `docs/release/homebrew.md`
- Create: `Scripts/verify-real-write-gate.sh`

**Interfaces:**
- Consumes: all H1, icon, and D1 work.
- Produces: a script that fails if public CLI flags no longer return `writeTestBlocked` or if `LumiSyncApp.swift` no longer injects `UnavailableKeyboardBacklightController`.
- Produces: CI jobs `swift-test`, `h1-process-safety`, and `bundle-structure`.

- [ ] **Step 1: Write the real-write gate script and observe current PASS**

The script runs the focused XCTest guard and performs exact source assertions:

```bash
swift test --filter KeyboardBacklightSafetyTests/testWriteCommandRemainsBlockedEvenWithBothExplicitFlags
grep -F 'keyboardBacklight: UnavailableKeyboardBacklightController()' Apps/LumiSyncApp/LumiSyncApp.swift
grep -F 'throw ParseError.writeTestBlocked' Sources/LumiSyncKeyboardProbe/KeyboardBacklightCommand.swift
```

Exit nonzero if any assertion fails.

- [ ] **Step 2: Add CI jobs with outer timeouts**

Use `timeout-minutes: 10` for ordinary tests and bundle checks, `timeout-minutes: 15` for H1 process tests. Commands:

```yaml
- run: swift test
- run: swift test --filter LumiSyncKeyboardProbeProcessTests
- run: bash Scripts/verify-real-write-gate.sh
- run: bash Scripts/build-app-icon.sh
- run: VERSION=0.2.0-ci BUILD_NUMBER=${{ github.run_number }} bash Scripts/build-unsigned-release-app.sh
- run: python3 Scripts/verify-release-bundle.py --app build/unsigned-release/LumiSync.app --manifest Packaging/LumiSync/NestedCode.json --version 0.2.0-ci --build-number ${{ github.run_number }}
```

Do not add signing secrets or pretend notarization runs in pull-request CI.

- [ ] **Step 3: Run all local gates fresh**

```bash
swift test
swift test --filter LumiSyncKeyboardProbeProcessTests
bash Scripts/verify-real-write-gate.sh
bash Scripts/build-app-icon.sh
VERSION=0.2.0-ci BUILD_NUMBER=1 bash Scripts/build-unsigned-release-app.sh
python3 Scripts/verify-release-bundle.py \
  --app build/unsigned-release/LumiSync.app \
  --manifest Packaging/LumiSync/NestedCode.json \
  --version 0.2.0-ci --build-number 1
```

Expected: PASS with zero test failures and no surviving owned process.

- [ ] **Step 4: Record exact H1 and D1 evidence**

In `docs/feasibility/keyboard-backlight.md`, list the passing process scenarios and explicitly state:

```text
H1 proves fake multi-process containment only. Real CoreBrightness writes remain blocked and require separately authorized H2 reference-machine qualification.
```

In `docs/release/homebrew.md`, record the verified D1 command and explicitly state that Developer ID signing, notarization, public GitHub Release, and Homebrew publication remain D2/D3 gates.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml Scripts/verify-real-write-gate.sh \
  docs/feasibility/keyboard-backlight.md docs/release/homebrew.md
git commit -m "ci: enforce H1 and unsigned bundle gates"
```

---

### Task 16: Independent H1 Review and Development-Entry Checkpoint

**Files:**
- Modify only files required by confirmed review findings.

**Interfaces:**
- Consumes: Tasks 1–15.
- Produces: reviewed H1 evidence and a branch that has entered development without enabling real writes.

- [ ] **Step 1: Review safety invariants independently**

Review the diff specifically for:

- supervisor ownership of original value;
- restoration execution after every mutation path;
- restoration result precedence;
- monotonic deadline propagation;
- process-group/descendant containment;
- exact protocol framing and size limits;
- absence of App-facing executable paths/selectors/device IDs;
- continued CLI and App real-write blocks; and
- tests that would fail if controller/writer process independence were removed.

- [ ] **Step 2: Fix only confirmed findings using RED–GREEN cycles**

For each confirmed bug, add the smallest failing regression test, run it to observe RED, implement the minimal fix, and run the focused plus full H1 suites.

- [ ] **Step 3: Run final fresh verification**

```bash
swift test
bash Scripts/verify-real-write-gate.sh
bash Scripts/build-app-icon.sh
VERSION=0.2.0-review BUILD_NUMBER=1 bash Scripts/build-unsigned-release-app.sh
git diff --check main...HEAD
git status --short
```

Expected: tests and gates PASS; only intentional tracked changes exist; no generated build outputs are staged.

- [ ] **Step 4: Update Orca checkpoint**

Set the worktree comment to `H1 fake recovery, native icon, and D1 bundle verified; real writes still blocked` and workspace status to `in-review`. Do not push, open a PR, merge, publish, or execute H2 without explicit authorization.

- [ ] **Step 5: Commit review fixes only if needed**

```bash
git add <only-confirmed-review-fix-files>
git commit -m "fix: harden backlight recovery containment"
```

Skip this commit when review finds no required change.

---

## Later-Gate Backlog

These are deliberately outside this implementation plan and require new approval/gating:

### H2: Reference-machine CoreBrightness qualification

- Keep `writeTestBlocked` until reviewed H2 code exists.
- Require explicit execution-time authorization before any real write.
- Verify Objective-C type encodings, exact hardware/macOS build identity, bounded `0.0 → restore → 0.5 → restore → 1.0 → restore`, readback after every operation, process cleanup, and non-sensitive evidence.
- Any timeout, mismatch, process leak, or restoration uncertainty leaves capability unavailable.

### H3: Signed least-privilege local service

- First prove ordinary user-scoped XPC/ServiceManagement access is sufficient.
- Authenticate audit token, Team ID, bundle identifier, and designated requirement.
- Specify installation, upgrade, repair, and removal.
- Do not add a root Helper without a new evidence-backed reviewed design.

### H4: Production App integration

- Replace the synchronous controller protocol with async bounded results.
- Add coalescing epsilon, deterministic supersession, safety-off bypass, transition cancellation, supervisor-health diagnostics, and capability invalidation.
- Only then replace `UnavailableKeyboardBacklightController`.

### D2: Developer ID and notarization

- Sign nested executables inside-out with explicit entitlements and Developer ID identities.
- Verify identifiers, Team ID, designated requirements, Hardened Runtime, `codesign --deep --strict`, `notarytool`, stapling, and `spctl`.
- Keep all credentials in Keychain or CI secret storage.

### D3: GitHub Release and Homebrew publication

- Requires explicit publication authorization.
- Publish immutable versioned ZIP and SHA-256.
- Replace Cask `0.1.0-dev` and `sha256 :no_check`.
- Test clean install, upgrade, service lifecycle, uninstall, zap, and residual process/service cleanup.
- Never describe notarization as Apple approval of CoreBrightness.

---

## Orca Parallelization DAG

- **Wave 0:** Task 1 on the parent development worktree.
- **Wave 1 after Task 1:**
  - H1 worker: Tasks 2–4.
  - Icon worker: Task 11.
  - D1 worker: Task 13.
- **Wave 2:**
  - H1 sequential safety chain: Tasks 5–10.
  - Icon worker: Task 12 after Task 11.
  - D1 worker: Task 14 after Tasks 12 and 13, because the final bundle consumes the corrected icon.
- **Wave 3:** Task 15 after H1, icon, and D1 tracks merge.
- **Wave 4:** Task 16 independent review and final checkpoint.

Use Orca-managed child worktrees for parallel writers. Each worker returns files changed, RED evidence, GREEN evidence, commit hashes, risks, and blockers. The controller reviews and integrates focused commits; workers do not push, open PRs, merge, publish, or execute real hardware writes.

## Self-Review

- **Spec coverage:** Tasks 1–10 implement H1 protocol, fake cross-process state, controller/supervisor/writer topology, deadlines, signal handling, result precedence, protocol abuse, and process containment. Tasks 11–12 implement icon alpha and visual acceptance. Tasks 13–15 implement D1 structure, CI, and retained gates. The later-gate backlog preserves H2–H4 and D2–D3 boundaries without prematurely implementing them.
- **Safety boundary:** The plan never makes `KeyboardBacklightCommand.writeTestBlocked` reachable as `.writeTest`, never wires CoreBrightness into the App, and adds an explicit CI gate against either regression.
- **Placeholder scan:** No unresolved placeholder marker, deferred implementation instruction, unspecified error-handling instruction, or undefined cross-task interface remains. Later gates are explicit out-of-scope backlog items with concrete entry conditions.
- **Type consistency:** `BacklightRequest`, `NormalizedBacklightValue`, `BacklightOperationResult`, `RestorationOutcome`, `OwnedProcessRunning`, and executable target names are introduced before use and remain consistent across later tasks.
- **Parallel conflicts:** `Package.swift` changes are sequenced through Task 1; icon and D1 ownership is separated; CI changes occur only at convergence.
