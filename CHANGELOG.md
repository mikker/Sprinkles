# Changelog

## Unreleased

- When the certificates can't be generated, Sprinkles shows what went wrong. Before, the "Generate and trust certificates" button and the certificate renewal silently did nothing.

## 1.3

### Setup and recovery

- "Onboarding…" is always in the menu bar menu. Before, it only appeared while holding Option.
- When the server can't start, the menu shows "Server not running" and an alert explains why: the certificate can't be read, something else is already listening on port 3133, or the scripts folder is missing. Before, the app said "Running" while nothing was listening, or sat on "Booting…" forever.
- Reset certificates no longer quits the app when the certificate files are already gone, and it removes the old Sprinkles certificate from your keychain instead of leaving it trusted.
- Sprinkles asks once to renew its local certificate after this update. The new certificate is only valid for localhost and only trusted for HTTPS to localhost, and it is renewed automatically before it expires. Before, the certificate was trusted for every site and silently expired after about two years.
- Picking a scripts folder on a drive that can't be bookmarked, or moving the folder later, no longer crashes the app or forgets the folder.
- The "Show this window on launch" checkbox shows its saved setting.

### Scripts and styles

- A script that ends in a line comment, including the bundled `global.js`, no longer breaks every script on a fresh install.
- CSS with backslashes, backticks or `${` works. Before, `content: "\201C"` broke the page's scripts.
- Styles apply on sites that enforce Trusted Types, such as GitHub.
- Files like `globalnews.ca.css` are served. Before, any name starting with "global" was skipped. Hidden `._` files are ignored.
- The server only listens on your Mac's loopback interface, and only the Sprinkles browser extensions can read your scripts. Before, any website or anyone on your network could fetch your domain list and scripts.
- Safari waits for the page body instead of giving up after a second, so scripts apply on slow pages, and a syntax error in `global.js` no longer stops your per-domain script.

### Browser extensions (Chrome 1.4.3, Firefox 1.4.3)

- Edits made while the extension's background worker was asleep are applied on the next page load. Before, most edits only took effect after a second edit or a manual reload.
- If the Sprinkles app isn't running, the extensions keep your scripts registered and say "Sprinkles app not running" in the toolbar tooltip. Before, a reload while the app was closed removed every script and showed a false "Please upgrade" badge.
- A script that fails to register no longer stops the others.
- Chrome's toolbar icon follows the light or dark theme, matching Firefox.
- Chrome explains when Developer mode and "Allow User Scripts" are needed, with a click to open the right settings page.

### Fixes

- The app no longer makes the extensions reload all scripts every time it is launched.
- Adding an empty stylesheet or renaming a file is noticed as a change.

## 1.2.1

- Injected CSS uses a Trusted Types policy so it applies on more sites.
- Fixed the global script in the Chrome and Firefox extensions (1.4.1), and matching `www.` hosts.

## 1.2

- Chrome and Firefox extensions moved to Manifest V3 (extensions 1.4).

## 1.1

- Update dependencies and modernize the project.
