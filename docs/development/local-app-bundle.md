# Local Development App Bundle

LumiSync can be assembled into a standard macOS application bundle for testing on the local machine without any paid Apple Developer Program assets. This path is deliberately separate from the production release flow: it uses an ad-hoc signature, has no Developer ID identity, has no hardened-runtime release assertion, is not notarized, and is not suitable for warning-free distribution to ordinary users.

The production requirements in `Scripts/package-release.sh` and `docs/release/homebrew.md` remain authoritative for anything published: Developer ID signing, hardened runtime, notarization, stapling, and a real release checksum are still mandatory.

## Build the local bundle

From the repository root:

```bash
bash Scripts/package-local-app.sh
```

Optional build metadata can be supplied without editing tracked files:

```bash
VERSION=0.1.0-local.2 BUILD_NUMBER=2 \
  bash Scripts/package-local-app.sh
```

The repeatable script performs these steps:

1. Builds the SwiftPM `LumiSyncApp` executable in release configuration.
2. Creates `build/local/LumiSync.app` with `Contents/Info.plist`, `Contents/MacOS/LumiSync`, and `Contents/Resources`.
3. Applies `codesign --sign - --timestamp=none`, which is an ad-hoc local signature only.
4. Runs strict local signature verification.
5. Creates a ZIP archive and a generated local Cask draft under `build/local/`.

The entire `build/` directory is gitignored. Do not copy these artifacts into `release/` or attach them to a GitHub release.

## Verify the local bundle

The following checks are expected to pass:

```bash
plutil -lint build/local/LumiSync.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 build/local/LumiSync.app
codesign --display --verbose=4 build/local/LumiSync.app
```

`codesign --display` should identify an ad-hoc signature rather than a `Developer ID Application` authority. Gatekeeper assessment is intentionally different:

```bash
spctl --assess --type execute --verbose=4 build/local/LumiSync.app
```

A rejection is the expected boundary because the bundle is not Developer ID signed or notarized. Record the actual result, but never convert a rejection into success or claim that ordinary users can install this build without warnings.

For a process-lifetime smoke test, launch the bundle, confirm its process remains alive, then terminate it cleanly:

```bash
open build/local/LumiSync.app
sleep 3
pgrep -x LumiSync
pkill -TERM -x LumiSync
```

The menu-bar app has no Dock icon because `LSUIElement` is enabled. The current production-safe keyboard controller still reports unavailable; local packaging does not bypass the hardware-write safety gate.

## Validate the local Homebrew Cask draft

`Scripts/package-local-app.sh` generates `build/local/lumisync-local.rb` with a `file://` URL and the exact SHA-256 of the local ZIP. It is a development-only Cask and is never published.

First perform non-installing structural checks:

```bash
ruby -c build/local/lumisync-local.rb
brew style build/local/lumisync-local.rb
```

Because the artifact is unnotarized, installation testing must never imply that a quarantined, ordinary-user install is supported. Older Homebrew versions exposed an explicit `--no-quarantine` switch:

```bash
brew install --cask --no-quarantine build/local/lumisync-local.rb
open /Applications/LumiSync.app
brew uninstall --cask lumisync-local
```

On Homebrew versions where `brew install` rejects `--no-quarantine`, stop at that exact failure boundary; do not silently fall back to a normal install, manually clear quarantine, tap the Cask, or publish it merely to force validation. A local path Cask may also be rejected by the installed Homebrew command contract, which must likewise be recorded as a tooling boundary.

## Project verification

Local app packaging does not replace package verification:

```bash
swift test
swift build --product LumiSyncApp
bash Scripts/package-local-app.sh
```
