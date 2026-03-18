# Repository Guidelines

## Project Structure & Module Organization

- `Sprinkles/` contains the macOS app source (Swift, storyboards/xibs, assets).
- `Sprinkles Extension/` is the Safari Web Extension target (Swift handler, plist, resources).
- `SprinklesTests/` holds XCTest unit tests.
- `Resources/` and `Sprinkles/Assets.xcassets/` store shared images and asset catalogs.
- `web-ext/` contains packaged Chrome/Firefox extension builds and source folders.
- `Updates/` stores prebuilt app archives used for distribution.
- `bin/` includes project scripts (version bumping, extension release, reset install).

## Build, Test, and Development Commands

- `open Sprinkles.xcodeproj` opens the Xcode project for local development.
- `xcodebuild -scheme Sprinkles -configuration Debug build` builds the macOS app.
- `xcodebuild -scheme Sprinkles test` runs unit tests.
- `bin/bump` increments build numbers and resolves Swift package dependencies.
- `bin/release-ext` zips Chrome/Firefox extension builds from `web-ext/`.

## Coding Style & Naming Conventions

- Swift is the primary language; follow Swift API Design Guidelines.
- Use UpperCamelCase for types and lowerCamelCase for methods/properties.
- Keep file names aligned with primary type names (e.g., `Server.swift`).
- Formatting is enforced via the Xcode build phase calling `/usr/bin/swift format -r -i .`.

## Testing Guidelines

- Tests use XCTest in `SprinklesTests/` (example: `SprinklesTests.swift`).
- Name test methods `testSomething()` and keep them focused and deterministic.
- Run tests from Xcode or via `xcodebuild -scheme Sprinkles test`.

## Commit & Pull Request Guidelines

- Recent history favors short, imperative subjects (e.g., “Fix …”, “Add …”).
- Release commits may be version-only tags (e.g., `v1.2.1`).
- PRs should include a clear description, testing notes, and screenshots for UI changes.

## Security & Configuration Tips

- Avoid committing generated archives in `Updates/` unless a release is intended.
- The app and extension rely on Xcode signing/entitlements; update `*.entitlements` carefully.
