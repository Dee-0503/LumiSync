#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build/local}"
readonly APP_NAME="LumiSync"
readonly VERSION="${VERSION:-0.1.0-local}"
readonly BUILD_NUMBER="${BUILD_NUMBER:-1}"
readonly CONFIGURATION="${CONFIGURATION:-release}"
readonly APP_PATH="$BUILD_DIR/$APP_NAME.app"
readonly D1_BUILD_DIR="$BUILD_DIR/d1"
readonly D1_APP_PATH="$D1_BUILD_DIR/unsigned-release/$APP_NAME.app"
readonly ARCHIVE_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"
readonly CASK_PATH="$BUILD_DIR/lumisync-local.rb"

mkdir -p "$BUILD_DIR"
rm -rf "$APP_PATH" "$ARCHIVE_PATH" "$D1_BUILD_DIR"

env \
  BUILD_DIR="$D1_BUILD_DIR" \
  VERSION="$VERSION" \
  BUILD_NUMBER="$BUILD_NUMBER" \
  CONFIGURATION="$CONFIGURATION" \
  bash "$SCRIPT_DIR/build-unsigned-release-app.sh"

if [[ ! -d "$D1_APP_PATH" ]]; then
  echo "Verified unsigned release app is missing: $D1_APP_PATH" >&2
  exit 1
fi

cp -R "$D1_APP_PATH" "$APP_PATH"

# This is intentionally an ad-hoc signature for local development. It is not a
# Developer ID signature and does not make the bundle notarized or Gatekeeper-ready.
codesign --force --sign - --timestamp=none "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
archive_sha256="$(shasum -a 256 "$ARCHIVE_PATH" | cut -d ' ' -f 1)"
archive_url="file://${ARCHIVE_PATH// /%20}"

cat >"$CASK_PATH" <<EOF
# typed: strict
# frozen_string_literal: true

cask "lumisync-local" do
  version "$VERSION"
  sha256 "$archive_sha256"

  url "$archive_url"
  name "LumiSync (Local Development)"
  desc "Ad-hoc-signed local development build of LumiSync"
  homepage "https://github.com/Dee-0503/LumiSync"

  conflicts_with cask: "lumisync"
  depends_on macos: :sonoma

  app "LumiSync.app"

  caveats <<~EOS
    This Cask is generated for local development only. The app is ad-hoc
    signed, is not Developer ID signed, and is not notarized. Only attempt an
    install when Homebrew supports its explicit --no-quarantine option; never
    treat this Cask as an ordinary-user distribution path.
  EOS
end
EOF

cat <<EOF
Created local development artifacts:
- App bundle: $APP_PATH
- ZIP archive: $ARCHIVE_PATH
- Local Cask draft: $CASK_PATH

The app uses an ad-hoc signature (codesign -). It is not Developer ID signed,
not notarized, and must not be represented as a warning-free public release.
EOF
