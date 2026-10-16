# Repository Guidelines

## Project Structure & Module Organization

- `Sprinkles/` contains the macOS app source (Swift, storyboards/xibs, assets).
- `Sprinkles Extension/` is the Safari Web Extension target (Swift handler, plist, resources).
- `SprinklesTests/` holds XCTest unit tests.
- `Resources/` and `Sprinkles/Assets.xcassets/` store shared images and asset catalogs.
- `web-ext/` contains packaged Chrome/Firefox extension builds and source folders.
- `Updates/` stores prebuilt app archives used for distribution.
- `scripts/` holds project scripts (build wrapper, version bumping, packaging, release, App Store Connect, reset install).
- `CHANGELOG.md` and `RELEASING.md` describe user-facing changes and the release flow; `Justfile` lists the commands.
- `cli/` is the Linux/CLI server (Go): same API as the Mac app. Build with `go build`, test with `go test ./...`.

## Build, Test, and Development Commands

- `just build` builds the Debug app, `just test` runs the unit tests, `just check` does both; logs land in `build/xcodebuild/` (`just log-tail`).
- `just run` rebuilds and runs the Debug app attached; `just open` opens the Xcode project.
- `just extensions` zips the Chrome/Firefox extensions into `dist/`; `just package`, `just upload` and `just release` are the release steps (see `RELEASING.md`).
- `Resources/` is gitignored except `AppIcon.appiconset/logo.png`, which the project references.

## Coding Style & Naming Conventions

- Swift is the primary language; follow Swift API Design Guidelines.
- Use UpperCamelCase for types and lowerCamelCase for methods/properties.
- Keep file names aligned with primary type names (e.g., `Server.swift`).
- Formatting is enforced via the Xcode build phase calling `/usr/bin/swift format -r -i .`.

## Testing Guidelines

- Tests use XCTest in `SprinklesTests/` (example: `SprinklesTests.swift`).
- Name test methods `testSomething()` and keep them focused and deterministic.
- Run tests from Xcode or via `xcodebuild -scheme Sprinkles test`.

## Changelog

- User-visible app or extension changes: update the top-level `## Unreleased` section of `CHANGELOG.md` in the same change. Write short bullets from the user's viewpoint; omit implementation details, internal changes, tests, docs and tooling. The release turns the section into the version heading, the GitHub release notes and the App Store "What's New".

## Commit & Pull Request Guidelines

- Recent history favors short, imperative subjects (e.g., “Fix …”, “Add …”).
- Release commits may be version-only tags (e.g., `v1.2.1`).
- PRs should include a clear description, testing notes, and screenshots for UI changes.

## Security & Configuration Tips

- Avoid committing generated archives in `Updates/` unless a release is intended.
- The app and extension rely on Xcode signing/entitlements; update `*.entitlements` carefully.
