# Release and Homebrew Verification

LumiSync releases must be Developer ID signed, hardened, notarized, and
stapled before publication. The packaging script stops before producing an
artifact when any required local prerequisite is missing; it never treats an
unsigned or unnotarized build as a release.

## Prerequisites

- A Git remote pointing to the intended GitHub repository.
- A reachable GitHub repository with permission to publish releases.
- `/Applications/Xcode.app`, including `notarytool` and `stapler`.
- A Developer ID Application signing identity in the login keychain.
- A signed and hardened `LumiSync.app` artifact.
- A notarization profile created with `xcrun notarytool store-credentials`.
- A published release artifact checksum to replace the development Cask's
  `:no_check` value.

Never commit signing certificates, passwords, App Store Connect keys, or
notarization profiles.

## Package a release

D1 produces a verified, unsigned release-shaped bundle; it is structure-only and
must never be distributed as a release. Build the input bundle first:

```bash
VERSION=0.1.0 BUILD_NUMBER=1 \
  bash Scripts/build-unsigned-release-app.sh
```

Then package the verified D1 bundle. The release script validates the bundle
before checking signing and notarization prerequisites, and exits nonzero when
any credential or release gate is unavailable:

```bash
VERSION=0.1.0 \
APP_PATH=build/unsigned-release/LumiSync.app \
NOTARYTOOL_PROFILE=LumiSync \
bash Scripts/package-release.sh
```

D2 (later work) must add inside-out Developer ID signing, Hardened Runtime,
identity and requirement verification, notarization, stapling, and Gatekeeper
assessment. D3 must replace the development Cask version and `sha256 :no_check`
only after explicit publication authorization.

The auditable D1 structure gate builds and verifies the unsigned release-shaped
bundle with:

```bash
bash Scripts/build-app-icon.sh
VERSION=0.2.0-ci BUILD_NUMBER=1 \
  bash Scripts/build-unsigned-release-app.sh
python3 Scripts/verify-release-bundle.py \
  --app build/unsigned-release/LumiSync.app \
  --manifest Packaging/LumiSync/NestedCode.json \
  --version 0.2.0-ci \
  --build-number 1
```

This evidence covers icon generation, nested executable placement, bundle metadata,
and unsigned bundle structure only. Developer ID signing, notarization, public
GitHub Release creation, and Homebrew publication remain explicitly blocked behind
D2/D3 and require separate authorization; CI does not receive signing secrets or
pretend to exercise those gates.

1. Build and sign `LumiSync.app` with the hardened runtime enabled.
2. Store notarization credentials in the keychain, for example:

   ```bash
   xcrun notarytool store-credentials "LumiSync"
   ```

3. Run the packaging script with the release version and credential profile:

   ```bash
   VERSION=0.1.0 \
   APP_PATH=build/Release/LumiSync.app \
   NOTARYTOOL_PROFILE=LumiSync \
   bash Scripts/package-release.sh
   ```

   Set `SIGNING_IDENTITY` only when the keychain contains more than one valid
   Developer ID Application identity. Successful packaging writes a notarized
   ZIP and its SHA-256 file under `release/`.

4. Publish both files in the matching GitHub release.
5. Replace `0.1.0-dev` and `:no_check` in `Casks/lumisync.rb` with the published
   version and exact SHA-256 value. The Cask must not ship publicly with either
   development placeholder.

## Verify the Cask

After the real GitHub artifact and checksum exist, run:

```bash
brew install --cask ./Casks/lumisync.rb
brew uninstall --cask lumisync
brew audit --cask --new ./Casks/lumisync.rb
```

Verify installation, launch at login, Helper installation, upgrade, and full
uninstall on macOS Sonoma or later. Uninstall must unload the planned
`com.dee0503.LumiSync` login service and `com.dee0503.LumiSyncHelper` Helper
label, then remove the Helper launch daemon and privileged executable.

## Local status on 2026-08-04

- Git remote: available as `origin` at `https://github.com/Dee-0503/LumiSync.git`.
- GitHub repository: publicly reachable; `git ls-remote origin HEAD` passed.
  Release-publishing authorization still requires an authenticated GitHub
  session.
- Xcode: blocked; `/Applications/Xcode.app` is absent.
- Signing: blocked; the keychain reports no valid code-signing identities.
- App artifact: blocked; no built and signed `LumiSync.app` exists yet.
- Notarization: blocked; no profile was provided for local verification.
- Published checksum: blocked; there is no real LumiSync release artifact yet.
- Homebrew audit: blocked by the installed Homebrew command contract. With
  Homebrew `5.1.11-189-g24605f6`, the required
  `brew audit --cask --new ./Casks/lumisync.rb` command exits `1` because path
  arguments are disabled and audit now requires a Cask name. The suggested
  `brew audit --cask --new lumisync` also exits `1` because the development
  Cask is not yet available in a tapped repository. Publish or tap the Cask,
  replace the development version and checksum, then repeat the audit by
  token. As a local structural check,
  `brew style ./Casks/lumisync.rb` passed with no offenses and `ruby -c`
  reported `Syntax OK`.

## Task 10 final verification on 2026-08-04

- `swift test`: **FAIL** (exit `1`). Swift 6.2.3 compiled the package sources,
  but the test target failed with `no such module 'XCTest'`. The active
  developer directory is `/Library/Developer/CommandLineTools`,
  `xcrun --find xctest` exits `72`, and full Xcode is absent, so this machine
  cannot run the XCTest suite. The `macos-14` CI runner is configured to run
  the same command with its Xcode toolchain.
- `swift run lumisync`: **PASS** (exit `0`). The executable built and printed
  `LumiSync 0.1.0`.
- `bash Scripts/package-release.sh`: **EXPECTED BLOCKED** (exit `1`). The
  script reported all four missing prerequisites: Xcode at
  `/Applications/Xcode.app`, a Developer ID Application signing identity, the
  signed `build/Release/LumiSync.app` artifact, and `NOTARYTOOL_PROFILE`.
- `brew audit --cask --new ./Casks/lumisync.rb`: **BLOCKED** (exit `1`).
  Homebrew rejected the path argument with
  `Calling brew audit [path ...] is disabled! Use brew audit [name ...] instead.`
