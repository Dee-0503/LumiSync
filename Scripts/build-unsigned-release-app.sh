#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly APP_NAME="LumiSync"
readonly PRODUCT_NAME="LumiSyncApp"
readonly VERSION="${VERSION:-0.1.0-dev}"
readonly BUILD_NUMBER="${BUILD_NUMBER:-1}"
readonly CONFIGURATION="${CONFIGURATION:-release}"
readonly BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"
readonly OUTPUT_DIR="$BUILD_DIR/unsigned-release"
readonly APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
readonly INFO_PLIST_SOURCE="$REPO_ROOT/Packaging/LumiSync/Info.plist"
readonly RESOURCES_SOURCE="$REPO_ROOT/Packaging/LumiSync/Resources"
readonly MANIFEST="$REPO_ROOT/Packaging/LumiSync/NestedCode.json"
readonly VERIFIER="$REPO_ROOT/Scripts/verify-release-bundle.py"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
  echo "VERSION must match a semantic release version: $VERSION" >&2
  exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "BUILD_NUMBER must be numeric: $BUILD_NUMBER" >&2
  exit 2
fi
if [[ "$CONFIGURATION" != "release" ]]; then
  echo "CONFIGURATION must be release for an unsigned release bundle: $CONFIGURATION" >&2
  exit 2
fi

readonly PRODUCTS=(
  "LumiSyncApp"
  "lumisync-backlight-controller"
  "lumisync-backlight-supervisor"
  "lumisync-backlight-writer"
)

for product in "${PRODUCTS[@]}"; do
  swift build \
    --package-path "$REPO_ROOT" \
    --configuration "$CONFIGURATION" \
    --product "$product"
done

bin_path="$(swift build \
  --package-path "$REPO_ROOT" \
  --configuration "$CONFIGURATION" \
  --show-bin-path)"

stage_root="$(mktemp -d "${TMPDIR:-/tmp}/lumisync-unsigned.XXXXXX")"
staged_app="$stage_root/$APP_NAME.app"
cleanup() {
  rm -rf -- "$stage_root"
}
trap cleanup EXIT

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Helpers" "$staged_app/Contents/Resources"
cp "$INFO_PLIST_SOURCE" "$staged_app/Contents/Info.plist"
cp -R "$RESOURCES_SOURCE/." "$staged_app/Contents/Resources/"

copy_product() {
  local product="$1"
  local destination="$2"
  local source="$bin_path/$product"
  if [[ ! -f "$source" || ! -x "$source" ]]; then
    echo "SwiftPM product is missing or not executable: $source" >&2
    exit 1
  fi
  cp "$source" "$staged_app/$destination"
  chmod 755 "$staged_app/$destination"
}

copy_product "LumiSyncApp" "Contents/MacOS/LumiSync"
copy_product "lumisync-backlight-controller" "Contents/Helpers/lumisync-backlight-controller"
copy_product "lumisync-backlight-supervisor" "Contents/Helpers/lumisync-backlight-supervisor"
copy_product "lumisync-backlight-writer" "Contents/Helpers/lumisync-backlight-writer"

resource_bundle="$bin_path/LumiSync_LumiSyncAppSupport.bundle"
if [[ ! -d "$resource_bundle" ]]; then
  echo "SwiftPM AppSupport resource bundle is missing: $resource_bundle" >&2
  exit 1
fi
cp -R "$resource_bundle" "$staged_app/Contents/Resources/"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$staged_app/Contents/Info.plist"
chmod 755 "$staged_app/Contents/MacOS" "$staged_app/Contents/Helpers"
chmod 644 "$staged_app/Contents/Info.plist"

python3 "$VERIFIER" \
  --app "$staged_app" \
  --manifest "$MANIFEST" \
  --version "$VERSION" \
  --build-number "$BUILD_NUMBER"

mkdir -p "$OUTPUT_DIR"
rm -rf -- "$APP_PATH"
mv "$staged_app" "$APP_PATH"

printf 'Created unsigned release bundle: %s\n' "$APP_PATH"
printf 'Version: %s\nBuild: %s\n' "$VERSION" "$BUILD_NUMBER"
printf 'No code signature was applied.\n'
