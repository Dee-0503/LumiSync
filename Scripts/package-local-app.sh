#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build/local}"
readonly APP_NAME="LumiSync"
readonly PRODUCT_NAME="LumiSyncApp"
readonly VERSION="${VERSION:-0.1.0-local}"
readonly BUILD_NUMBER="${BUILD_NUMBER:-1}"
readonly CONFIGURATION="${CONFIGURATION:-release}"
readonly APP_PATH="$BUILD_DIR/$APP_NAME.app"
readonly CONTENTS_PATH="$APP_PATH/Contents"
readonly EXECUTABLE_PATH="$CONTENTS_PATH/MacOS/$APP_NAME"
readonly ARCHIVE_PATH="$BUILD_DIR/$APP_NAME-$VERSION.zip"
readonly CASK_PATH="$BUILD_DIR/lumisync-local.rb"
readonly INFO_PLIST_SOURCE="$REPO_ROOT/Packaging/LumiSync/Info.plist"
readonly RESOURCES_SOURCE="$REPO_ROOT/Packaging/LumiSync/Resources"

mkdir -p "$BUILD_DIR"
rm -rf "$APP_PATH" "$ARCHIVE_PATH"

swift build \
  --package-path "$REPO_ROOT" \
  --configuration "$CONFIGURATION" \
  --product "$PRODUCT_NAME"

bin_path="$(swift build \
  --package-path "$REPO_ROOT" \
  --configuration "$CONFIGURATION" \
  --show-bin-path)"
product_path="$bin_path/$PRODUCT_NAME"
resource_bundle_path="$bin_path/LumiSync_LumiSyncAppSupport.bundle"

if [[ ! -x "$product_path" ]]; then
  echo "SwiftPM product is missing or not executable: $product_path" >&2
  exit 1
fi

if [[ ! -d "$resource_bundle_path" ]]; then
  echo "SwiftPM AppSupport resource bundle is missing: $resource_bundle_path" >&2
  exit 1
fi

mkdir -p "$CONTENTS_PATH/MacOS" "$CONTENTS_PATH/Resources"
cp "$product_path" "$EXECUTABLE_PATH"
cp "$INFO_PLIST_SOURCE" "$CONTENTS_PATH/Info.plist"
cp -R "$RESOURCES_SOURCE/." "$CONTENTS_PATH/Resources/"
cp -R "$resource_bundle_path" "$CONTENTS_PATH/Resources/"
chmod 755 "$EXECUTABLE_PATH"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS_PATH/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS_PATH/Info.plist"

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
