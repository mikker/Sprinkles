# Releases

Versions are `X.Y`, bumped by 0.1 each release (`X.Y.Z` for a hotfix). User-visible changes go in `CHANGELOG.md` under `## Unreleased` as they land, written for users; the `sprinkles-release` skill in `.agents/skills` reviews the delta and those notes before a release.

Sprinkles ships through the Mac App Store, so a release has two halves: the Mac app (with the Safari extension inside it) goes to App Store Connect, and the Chrome and Firefox extensions go to their stores as zips. GitHub gets a release with the changelog section as its notes and the extension zips as assets.

## Mac app

Run `just release` from a clean `main` that matches `origin/main` (or `just release 1.4` to pick the version). It runs the tests, renames `## Unreleased` to `## 1.4`, sets `MARKETING_VERSION` and a build number that is the commit count plus 9 (never lower than the last one), commits and pushes `Release 1.4`, archives the app for the App Store with automatic signing, exports `dist/Sprinkles.pkg`, uploads it to App Store Connect, tags `v1.4`, creates a GitHub release with the `## 1.4` notes and the extension zips, and then, through `scripts/appstore.py`, creates the 1.4 App Store version, sets its What's New text to the same notes, attaches the uploaded build once App Store Connect has processed it, and submits it for review. Running it again without adding commits reuses the `Release 1.4` commit and retries whatever failed; an uploaded build is never replaced, and a tag is never moved.

`just package` does the archive and export without uploading. `just upload` uploads an existing `dist/Sprinkles.pkg`. `just appstore <command>` runs one step by hand: `builds`, `prepare 1.4`, `submit 1.4`, `status`.

Review happens on Apple's side. When the version is approved it is released automatically (the version is created with automatic release), and `scripts/appstore.py status` shows where it is.

## Extensions

The Chrome and Firefox extensions have their own version in `web-ext/chrome/manifest.json` and `web-ext/ff/manifest.json`, bumped by hand when they change. `just release` refuses to run when files under `web-ext/` changed since the last tag and the manifest versions did not. The Safari extension takes the app's version.

`just extensions` zips both into `dist/chrome-extension.zip` and `dist/firefox-extension.zip`. `just release` then runs `scripts/extensions-publish.py`, which uploads the Chrome zip to the Web Store item and publishes it (Google reviews it, then it goes live), and uploads the Firefox zip to addons.mozilla.org, waits for its validation, and creates the listed version with the changelog section as release notes (Mozilla reviews it). A version that is already on a store is skipped, so rerunning is safe. `just publish-extensions chrome|firefox|all [--dry-run]` runs it by hand; `scripts/release-ext.sh --open` is the manual fallback.

Store listings (App Store, Chrome Web Store privacy practices, AMO) use the privacy policy at https://getsprinkles.app/privacy and the terms at https://getsprinkles.app/terms, both pages in the getsprinkles.app site repo.

## Credentials

Everything runs on your Mac with your own credentials in the ignored `.env`; nothing is in CI.

- **Signing.** Targets use automatic signing with team `DDB8SQMXS9`. The archive and export pass `-allowProvisioningUpdates` and sign through the Apple ID signed into Xcode (Xcode › Settings › Accounts), which creates the Mac App Store provisioning profile the first time and uses the team's cloud-managed Apple Distribution certificate. The API key below is never used for signing: a team key is not allowed to use cloud-managed distribution certificates unless that is ticked when it is created, and the export then fails with "Cloud signing permission error". If signing fails with "Failed to Use Accounts" or asks for credentials, sign in to Xcode again.
- **App Store Connect API key.** Create a team key with the App Manager role at [App Store Connect › Users and Access › Integrations › App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api), download the `.p8` once, and put it at `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`, where `xcodebuild` also looks. Put the IDs in `.env` (ignored) so `just` loads them:

  ```sh
  ASC_KEY_ID=ABC123DEFG
  ASC_ISSUER_ID=12345678-1234-1234-1234-123456789012
  ```

  The upload sends the exported `dist/Sprinkles.pkg` with `xcrun altool --upload-app` and this key, so nothing is signed again at upload time; `scripts/appstore.py` signs its own JWTs with it using `openssl`, so no Python packages are needed. A Developer-role key (such as the one notarytool uses) can upload but can't create versions or submit; the App Manager role can do all of it. `prepare` also answers Apple's age rating questionnaire (all "none" for Sprinkles; the answers live in `scripts/appstore.py`).
- **Chrome Web Store API.** Once: in [Google Cloud Console](https://console.cloud.google.com/) create a project, enable the "Chrome Web Store API", set up the OAuth consent screen (External, add your own Google account as a test user), and create an OAuth client of type "Desktop app". Put its ID and secret in `.env` as `CWS_CLIENT_ID` and `CWS_CLIENT_SECRET`, then run `scripts/cws-auth.py`: it opens the consent page, you sign in with the account that owns the Web Store item, and it prints the `CWS_REFRESH_TOKEN` line for `.env`. Refresh tokens from a consent screen left in "Testing" expire after 7 days, so publish the consent screen (no verification is needed for your own account) or rerun `cws-auth.py` when uploads fail with `invalid_grant`.
- **addons.mozilla.org API.** Once: generate credentials at [addons.mozilla.org/developers/addon/api/key](https://addons.mozilla.org/developers/addon/api/key/) and put them in `.env` as `AMO_JWT_ISSUER` (the "JWT issuer", `user:…`) and `AMO_JWT_SECRET`.
- **GitHub.** `gh` must be logged in with push access to `mikker/Sprinkles`.

## Things learned the hard way

- Apple's 2025 age rating questionnaire blocks submission until answered; the answers live on the editable app info, not the version, and `scripts/appstore.py prepare` sets them (all "none").
- The Chrome Web Store refuses to publish until the item's Privacy practices tab is filled in once by hand in the developer console. Chrome blocks browser automation on both the developer console and Google's sign-in pages, so that form and the OAuth consent click are always manual.
- Keep the Google Auth Platform in "In production": in "Testing" every refresh token dies after 7 days.
- An App Store Connect key with only the Developer role can upload but not create versions or submit.
- A "Release X.Y" commit that was pushed but whose later steps failed is reused on rerun; do not amend or reset it.
- Signing and uploading are separate: the cloud-managed distribution certificate is only reachable through the Apple ID in Xcode, and the API key only talks to App Store Connect. Passing the key to `xcodebuild -exportArchive` made the export try to sign with the key and fail (1.3.1), and an expired Xcode account token made the old upload-by-export fail the other way. `altool` prints nothing while it transfers; a few minutes is normal, and `just appstore builds` shows the build once it lands.

See `docs/vm-testing.md` for trying a build in a Tart VM before releasing.

## What the scripts need

Xcode 26+, `just`, `gh`, `python3` 3.9+, `openssl`. `scripts/agent-build.sh` wraps `xcodebuild` with `build/dd` as derived data and keeps full logs under `build/xcodebuild/`; `just log-tail` shows the newest one. Output goes to ignored `build/` and `dist/`.
