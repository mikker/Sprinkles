# Releases

Versions are `X.Y`, bumped by 0.1 each release (`X.Y.Z` for a hotfix). User-visible changes go in `CHANGELOG.md` under `## Unreleased` as they land, written for users; the `sprinkles-release` skill in `.agents/skills` reviews the delta and those notes before a release.

Sprinkles ships through the Mac App Store, so a release has two halves: the Mac app (with the Safari extension inside it) goes to App Store Connect, and the Chrome and Firefox extensions go to their stores as zips. GitHub gets a release with the changelog section as its notes and the extension zips as assets.

## Mac app

Run `just release` from a clean `main` that matches `origin/main` (or `just release 1.4` to pick the version). It runs the tests, renames `## Unreleased` to `## 1.4`, sets `MARKETING_VERSION` and a build number that is the commit count plus 9 (never lower than the last one), commits and pushes `Release 1.4`, archives the app for the App Store with automatic signing, exports `dist/Sprinkles.pkg`, uploads it to App Store Connect, tags `v1.4`, creates a GitHub release with the `## 1.4` notes and the extension zips, and then, through `scripts/appstore.py`, creates the 1.4 App Store version, sets its What's New text to the same notes, attaches the uploaded build once App Store Connect has processed it, and submits it for review. Running it again without adding commits reuses the `Release 1.4` commit and retries whatever failed; an uploaded build is never replaced, and a tag is never moved.

`just package` does the archive and export without uploading. `just upload` uploads an existing `dist/Sprinkles.pkg`. `just appstore <command>` runs one step by hand: `builds`, `prepare 1.4`, `submit 1.4`, `status`.

Review happens on Apple's side. When the version is approved it is released automatically (the version is created with automatic release), and `scripts/appstore.py status` shows where it is.

## Extensions

The Chrome and Firefox extensions have their own version in `web-ext/chrome/manifest.json` and `web-ext/ff/manifest.json`, bumped by hand when they change. `just release` refuses to run when files under `web-ext/` changed since the last tag and the manifest versions did not. The Safari extension takes the app's version.

`just extensions` zips both into `dist/chrome-extension.zip` and `dist/firefox-extension.zip`. Submitting them is manual: the [Chrome Web Store developer console](https://chrome.google.com/webstore/devconsole) and [addons.mozilla.org](https://addons.mozilla.org/developers/addon/getsprinkles/versions/submit/). `scripts/release-ext.sh` opens both.

## Credentials

Everything runs on your Mac with your own credentials; nothing is in CI.

- **Signing.** Targets use automatic signing with team `DDB8SQMXS9`. The export and upload pass `-allowProvisioningUpdates`, so Xcode creates the Apple Distribution certificate and the Mac App Store provisioning profile the first time, using the Apple ID signed into Xcode or the API key below.
- **App Store Connect API key.** Create a team key with the App Manager role at [App Store Connect › Users and Access › Integrations › App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api), download the `.p8` once, and put it at `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`, where `xcodebuild` also looks. Put the IDs in `.env` (ignored) so `just` loads them:

  ```sh
  ASC_KEY_ID=ABC123DEFG
  ASC_ISSUER_ID=12345678-1234-1234-1234-123456789012
  ```

  The upload uses the key through `xcodebuild`; `scripts/appstore.py` signs its own JWTs with it using `openssl`, so no Python packages are needed. A Developer-role key (such as the one notarytool uses) can upload but can't create versions or submit; the App Manager role can do all of it.
- **GitHub.** `gh` must be logged in with push access to `mikker/Sprinkles`.

## What the scripts need

Xcode 26+, `just`, `gh`, `python3` 3.9+, `openssl`. `scripts/agent-build.sh` wraps `xcodebuild` with `build/dd` as derived data and keeps full logs under `build/xcodebuild/`; `just log-tail` shows the newest one. Output goes to ignored `build/` and `dist/`.
