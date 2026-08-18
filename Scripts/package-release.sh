#!/usr/bin/env bash

set -euo pipefail

readonly APP_NAME="LumiSync"
readonly VERSION="${VERSION:-0.1.0}"
readonly APP_PATH="${APP_PATH:-build/unsigned-release/LumiSync.app}"
readonly RELEASE_DIR="${RELEASE_DIR:-release}"
readonly XCODE_PATH="${XCODE_PATH:-/Applications/Xcode.app}"
readonly SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
readonly NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MANIFEST="$REPO_ROOT/Packaging/LumiSync/NestedCode.json"
readonly VERIFIER="$REPO_ROOT/Scripts/verify-release-bundle.py"

failures=()

fail() {
  failures+=("$1")
}

if [[ ! -d "$APP_PATH" ]]; then
  fail "Verified unsigned release app artifact is required at $APP_PATH (override with APP_PATH)."
elif ! python3 "$VERIFIER" \
  --app "$APP_PATH" \
  --manifest "$MANIFEST" \
  --version "$VERSION" \
  --build-number "${BUILD_NUMBER:-1}"; then
  fail "APP_PATH failed unsigned release bundle verification."
fi

if [[ ! -d "$XCODE_PATH" ]]; then
  fail "Xcode is required at $XCODE_PATH (override with XCODE_PATH)."
elif ! DEVELOPER_DIR="$XCODE_PATH/Contents/Developer" xcrun --find notarytool >/dev/null 2>&1; then
  fail "The selected Xcode does not provide notarytool."
fi

identity_output="$(security find-identity -v -p codesigning 2>&1 || true)"
if [[ -n "$SIGNING_IDENTITY" ]]; then
  if ! grep -Fq "\"$SIGNING_IDENTITY\"" <<<"$identity_output"; then
    fail "Signing identity '$SIGNING_IDENTITY' is not available in the keychain."
  fi
elif ! grep -q '"Developer ID Application:' <<<"$identity_output"; then
  fail "A Developer ID Application signing identity is required (or set SIGNING_IDENTITY)."
fi

if [[ ! -d "$APP_PATH" ]]; then
  fail "Signed app artifact is required at $APP_PATH (override with APP_PATH)."
fi

if [[ -z "$NOTARYTOOL_PROFILE" ]]; then
  fail "NOTARYTOOL_PROFILE must name credentials stored with 'xcrun notarytool store-credentials'."
elif ! security find-generic-password \
  -s "com.apple.gke.notary.tool" \
  -a "$NOTARYTOOL_PROFILE" >/dev/null 2>&1; then
  fail "Notarization credentials profile '$NOTARYTOOL_PROFILE' is absent from the keychain."
fi

if (( ${#failures[@]} > 0 )); then
  echo "Release prerequisites are not satisfied:" >&2
  for failure in "${failures[@]}"; do
    echo "- $failure" >&2
  done
  exit 1
fi

developer_dir="$XCODE_PATH/Contents/Developer"
archive_name="$APP_NAME-$VERSION.zip"
checksum_name="$archive_name.sha256"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lumisync-release.XXXXXX")"
staged_app="$tmp_dir/$APP_NAME.app"
submission_archive="$tmp_dir/submission.zip"
final_archive="$tmp_dir/$archive_name"

cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

echo "Verifying signed app artifact..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
signature_details="$(codesign --display --verbose=4 "$APP_PATH" 2>&1)"
if ! grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' <<<"$signature_details"; then
  echo "Release app is not signed with the hardened runtime." >&2
  exit 1
fi

ditto "$APP_PATH" "$staged_app"
ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$submission_archive"

echo "Submitting $archive_name for notarization..."
DEVELOPER_DIR="$developer_dir" xcrun notarytool submit "$submission_archive" \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait

echo "Stapling and validating the notarization ticket..."
DEVELOPER_DIR="$developer_dir" xcrun stapler staple "$staged_app"
DEVELOPER_DIR="$developer_dir" xcrun stapler validate "$staged_app"

ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$final_archive"
mkdir -p "$RELEASE_DIR"
mv "$final_archive" "$RELEASE_DIR/$archive_name"
shasum -a 256 "$RELEASE_DIR/$archive_name" >"$RELEASE_DIR/$checksum_name"

echo "Created $RELEASE_DIR/$archive_name"
echo "Created $RELEASE_DIR/$checksum_name"
