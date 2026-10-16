#!/usr/bin/env bash
# Archives Sprinkles for the App Store, exports dist/Sprinkles.pkg and zips the extensions; or, with --upload,
# uploads the archive to App Store Connect. Usage: scripts/package-release.sh [X.Y] | --upload
# Signing is automatic with -allowProvisioningUpdates, so Xcode creates the Apple Distribution certificate and
# the Mac App Store profile on first use. Set ASC_KEY_ID and ASC_ISSUER_ID (see RELEASING.md) to authenticate
# with an App Store Connect API key instead of the Apple ID signed into Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
archive="$PWD/build/Sprinkles.xcarchive"
pbxproj=Sprinkles.xcodeproj/project.pbxproj

auth_flags=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  key="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
  [[ -f "$key" ]] || { echo "ASC_KEY_ID is set but $key is missing" >&2; exit 1; }
  [[ -n "${ASC_ISSUER_ID:-}" ]] || { echo 'Set ASC_ISSUER_ID along with ASC_KEY_ID' >&2; exit 1; }
  auth_flags+=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

version="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);$/\1/p' "$pbxproj" | head -1)"
build="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \(.*\);$/\1/p' "$pbxproj" | head -1)"
archive_version() { /usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$archive/Info.plist"; }
archive_build() { /usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$archive/Info.plist"; }

if [[ "${1:-}" == --upload ]]; then
  [[ -d "$archive" ]] || { echo "No archive at $archive; run scripts/package-release.sh first" >&2; exit 1; }
  marker="dist/uploaded-$(archive_version)-$(archive_build).json"
  if [[ -f "$marker" ]]; then
    echo "==> Build $(archive_version) ($(archive_build)) was already uploaded ($marker); not uploading again"
    exit 0
  fi
  echo "==> Uploading Sprinkles $(archive_version) ($(archive_build)) to App Store Connect"
  rm -rf build/upload
  xcodebuild -exportArchive -archivePath "$archive" -exportPath build/upload \
    -exportOptionsPlist scripts/ExportOptions-upload.plist "${auth_flags[@]}"
  printf '{"version":"%s","build":"%s","uploadedAt":"%s"}\n' "$(archive_version)" "$(archive_build)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker"
  echo "==> Uploaded; App Store Connect processes it in a few minutes (scripts/appstore.py builds)"
  exit 0
fi

expected="${1:-}"
expected="${expected#v}"
[[ -z "$expected" || "$expected" == "$version" ]] || { echo "Project version is $version, not $expected" >&2; exit 1; }
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "Unexpected MARKETING_VERSION $version" >&2; exit 1; }

echo "==> Archiving Sprinkles $version ($build) for the App Store"
rm -rf "$archive" build/export
scripts/agent-build.sh archive -project Sprinkles.xcodeproj -scheme Sprinkles -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$archive" "${auth_flags[@]}"
[[ "$(archive_version)" == "$version" && "$(archive_build)" == "$build" ]] \
  || { echo "Archive is $(archive_version) ($(archive_build)), expected $version ($build)" >&2; exit 1; }

echo "==> Exporting dist/Sprinkles.pkg"
xcodebuild -exportArchive -archivePath "$archive" -exportPath build/export \
  -exportOptionsPlist scripts/ExportOptions-appstore.plist "${auth_flags[@]}"
mkdir -p dist
rm -f dist/Sprinkles.pkg
cp build/export/Sprinkles.pkg dist/Sprinkles.pkg
pkgutil --check-signature dist/Sprinkles.pkg | head -3
codesign --verify --deep --strict "$archive/Products/Applications/Sprinkles.app"

scripts/release-ext.sh
echo "==> dist/Sprinkles.pkg, dist/chrome-extension.zip and dist/firefox-extension.zip are ready"
