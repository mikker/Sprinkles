---
name: sprinkles-release
description: Review Sprinkles changes and changelog notes since the last release, then publish with `just release`.
---

# Sprinkles release

`RELEASING.md` is the canonical release procedure; read it before publishing.

## Readiness

Review the delta from the newest `v*` tag:

```bash
git log --format='%h %s%n%b' "$(git tag --list 'v*' --sort=-v:refname | head -1)"..origin/main
git diff --stat "$(git tag --list 'v*' --sort=-v:refname | head -1)"..origin/main
```

Include local commits that are not yet pushed, and ask before pushing them.

Check `README.md` and `AGENTS.md` against the delta for anything a user or contributor relies on, and fix
stale text before release. If files under `web-ext/chrome` or `web-ext/ff` changed, their
`manifest.json` versions must be bumped; `just release` refuses otherwise. Open GitHub issues closed by
the delta should be mentioned in the notes where that helps a user recognise their report.

Run `just check`. For changes to the server, certificates or extensions, the Tart VM recipe in memory
(`sprinkles-vm-testing`) is the way to try the real app and all three browsers; it is optional, not a
publication requirement.

## Changelog

`CHANGELOG.md` must have an accurate `## Unreleased` section for the delta. Write it as end-user
release notes: user-visible effects from the user's viewpoint, no implementation details, nothing
purely internal (release tooling, refactors, tests, doc reorganizations). Bullets may accumulate
during development; before approval, consolidate them into short, direct bullets, grouped under `###`
headings by area only when there are enough to need it, with fixes last under `### Fixes`. Name the
extension versions in a heading when the Chrome or Firefox extensions changed. Put a plain upgrade
note first when the user must do something after updating, such as answering the certificate renewal
prompt. The same text becomes the App Store "What's New", so keep it readable as plain text.

## Approval

Show the final `## Unreleased` section verbatim with the version it will ship as, and get approval for
that concrete release unless it was already given in this conversation for the same version and notes.
Ask again only if the version or notes materially change. Put the notes in the approval question itself,
since text before the question may not be visible while the user answers. A readiness review alone
does not authorize publication.

## Publish

```bash
just release          # latest tag + 0.1
just release 1.4      # explicit version
```

Start from a clean local `main` that exactly matches `origin/main`. The command tests, turns
`## Unreleased` into `## X.Y`, sets the version and build number, commits and pushes `Release X.Y`,
archives and uploads the app to App Store Connect, tags, publishes the GitHub release with that
changelog section as its notes and the extension zips as assets, then creates the App Store version
with the same notes, attaches the build and submits it for review. After a failure, rerun the same
command without adding commits; it reuses the prepared commit and never re-uploads a build. Signing
and the upload need the local keychain and the App Store Connect API key, so run it on the release Mac.

The Chrome Web Store and addons.mozilla.org uploads stay manual: `scripts/release-ext.sh --open`.
