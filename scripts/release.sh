#!/usr/bin/env bash
# Prepares, tests, packages, uploads, tags, publishes a GitHub release and submits the App Store version
# from a clean, pushed main. Usage: scripts/release.sh [X.Y]   (run again to retry a failed release)
# Without a version it bumps the latest tag by 0.1. Preparing turns CHANGELOG.md's `## Unreleased` into
# `## X.Y`, sets the project version and build number and commits and pushes "Release X.Y"; a rerun reuses
# that commit. An uploaded build is never replaced and a tag is never moved.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-}"
version="${version#v}"
repo=mikker/Sprinkles
pbxproj=Sprinkles.xcodeproj/project.pbxproj

# Prints the body of a `## ` section of CHANGELOG.md, without surrounding blank lines.
changelog_section() {
  awk -v heading="## $1" '
    $0 == heading { found = 1; next }
    found && /^## / { exit }
    found { print }
  ' CHANGELOG.md | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}'
}

manifest_version() { python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])'; }

# The Chrome and Firefox extensions carry their own version; refuse to release changed extensions under
# an old number, since the stores reject re-uploads of a version.
check_extension_versions() {
  local last="$1" dir
  for dir in chrome ff; do
    if [[ -n "$(git diff --name-only "$last"..HEAD -- "web-ext/$dir")" ]]; then
      local was now
      was="$(git show "$last:web-ext/$dir/manifest.json" 2>/dev/null | manifest_version || echo none)"
      now="$(manifest_version < "web-ext/$dir/manifest.json")"
      [[ "$was" != "$now" ]] || { echo "web-ext/$dir changed since $last but its manifest version is still $now; bump it" >&2; exit 1; }
    fi
  done
}

[[ "$(git branch --show-current)" == main ]] || { echo 'Release from main' >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit your changes first' >&2; exit 1; }
git fetch -q origin main
latest="$(gh release view -R "$repo" --json tagName --jq .tagName 2>/dev/null || true)"
last_tag="$(git tag --list 'v*' --sort=-v:refname | head -1)"

prepared="$(git log -1 --format=%s | sed -n 's/^Release \([0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)*\)$/\1/p')"
if [[ -n "$prepared" ]]; then
  [[ -z "$version" || "$version" == "$prepared" ]] || { echo "HEAD prepares $prepared, not $version" >&2; exit 1; }
  version="$prepared"
  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
    [[ "$(git rev-parse HEAD^)" == "$(git rev-parse origin/main)" ]] || { echo 'Push or pull main first' >&2; exit 1; }
    git push -q origin HEAD:main
  fi
else
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo 'Push or pull main first' >&2; exit 1; }
  if [[ -z "$version" ]]; then
    [[ -n "$last_tag" ]] || { echo 'No v* tag to bump; pass a version' >&2; exit 1; }
    version="$(python3 -c 'import sys; m, n = sys.argv[1][1:].split(".")[:2]; print(f"{m}.{int(n) + 1}")' "$last_tag")"
  fi
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo 'Expected version X.Y' >&2; exit 1; }
tag="v$version"
if [[ -n "$latest" && "$latest" != "$tag" ]]; then
  python3 - "$tag" "$latest" <<'PY'
import sys
v = lambda s: tuple(int(x) for x in s.removeprefix('v').split('.'))
if v(sys.argv[1]) <= v(sys.argv[2]): raise SystemExit(f'{sys.argv[1]} is not newer than the latest release {sys.argv[2]}')
PY
fi

if [[ -z "$prepared" ]]; then
  [[ "$(grep -cx '## Unreleased' CHANGELOG.md || true)" == 1 ]] || { echo 'CHANGELOG.md needs one ## Unreleased section' >&2; exit 1; }
  [[ -n "$(changelog_section Unreleased)" ]] || { echo 'The ## Unreleased section of CHANGELOG.md is empty' >&2; exit 1; }
  git rev-parse --verify -q "$tag" >/dev/null && { echo "Tag $tag already exists" >&2; exit 1; }
  [[ -n "$last_tag" ]] && check_extension_versions "$last_tag"
  echo "==> Testing before preparing $version"
  scripts/agent-build.sh test -project Sprinkles.xcodeproj -scheme Sprinkles -destination 'platform=macOS'
  sed -i '' "s/^## Unreleased\$/## $version/" CHANGELOG.md
  sed -i '' "s/^\([[:space:]]*MARKETING_VERSION = \).*;\$/\1$version;/" "$pbxproj"
  scripts/bump.sh
  git add CHANGELOG.md "$pbxproj"
  git add -u Sprinkles.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved 2>/dev/null || true
  git commit -q -m "Release $version"
  git push -q origin HEAD:main
  echo "==> Prepared and pushed Release $version"
fi

head="$(git rev-parse HEAD)"
grep -q "MARKETING_VERSION = $version;" "$pbxproj" || { echo "$pbxproj does not name $version" >&2; exit 1; }
build="$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \(.*\);$/\1/p' "$pbxproj" | head -1)"
if git rev-parse --verify -q "$tag" >/dev/null; then
  [[ "$head" == "$(git rev-list -n 1 "$tag")" ]] || { echo "Tag $tag points to another commit" >&2; exit 1; }
fi
mkdir -p dist
changelog_section "$version" > dist/release-notes.md
[[ -s dist/release-notes.md ]] || { echo "CHANGELOG.md has no notes under ## $version" >&2; exit 1; }

if [[ ! -f "dist/uploaded-$version-$build.json" ]]; then
  [[ -n "$prepared" ]] && scripts/agent-build.sh test -project Sprinkles.xcodeproj -scheme Sprinkles -destination 'platform=macOS'
  scripts/package-release.sh "$version"
  [[ "$head" == "$(git rev-parse HEAD)" && -z "$(git status --porcelain)" ]] || { echo 'Source changed during packaging; retry' >&2; exit 1; }
  scripts/package-release.sh --upload
else
  echo "==> Build $version ($build) is already uploaded"
  scripts/release-ext.sh
fi

git rev-parse --verify -q "$tag" >/dev/null || git tag -a "$tag" -m "Release $version"
git push -q origin "$tag"
if gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
  gh release edit "$tag" -R "$repo" --notes-file dist/release-notes.md
else
  gh release create "$tag" -R "$repo" --verify-tag --title "Sprinkles $version" --notes-file dist/release-notes.md
fi
gh release upload "$tag" -R "$repo" dist/chrome-extension.zip dist/firefox-extension.zip --clobber
gh release edit "$tag" -R "$repo" --latest >/dev/null
echo "==> https://github.com/$repo/releases/tag/$tag"

if [[ -z "${ASC_KEY_ID:-}" ]]; then
  cat >&2 <<EOF
==> Build $version ($build) is uploaded and the GitHub release is published, but the App Store version was not
    created or submitted: set ASC_KEY_ID and ASC_ISSUER_ID (RELEASING.md) and rerun, or finish it in App Store Connect.
    The extension zips in dist/ were not uploaded either (scripts/extensions-publish.py).
EOF
  exit 2
fi
python3 scripts/appstore.py prepare "$version" --build "$build" --notes dist/release-notes.md --wait
python3 scripts/appstore.py submit "$version"
echo "==> Submitted $version for review"

if [[ -z "${CWS_REFRESH_TOKEN:-}" || -z "${AMO_JWT_SECRET:-}" ]]; then
  cat >&2 <<EOF
==> The extension zips in dist/ were not uploaded: set CWS_CLIENT_ID, CWS_CLIENT_SECRET, CWS_REFRESH_TOKEN and
    AMO_JWT_ISSUER, AMO_JWT_SECRET (RELEASING.md) and rerun, or use scripts/release-ext.sh --open.
EOF
  exit 2
fi
python3 scripts/extensions-publish.py all --notes dist/release-notes.md
