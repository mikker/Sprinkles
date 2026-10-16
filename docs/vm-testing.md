# Testing Sprinkles end to end in a VM

The unit tests cover the server's pure functions. Everything else, from onboarding and certificate trust to the three browser extensions, is best tried in a throwaway macOS VM with [Tart](https://tart.run). This is how it was done for 1.3 on macOS 27; the helper scripts described here are small enough to recreate from the notes.

## VM

```sh
tart clone ghcr.io/cirruslabs/macos-golden-gate-base:latest sprinkles-test
tart run sprinkles-test --no-graphics &
tart ip sprinkles-test
```

The Cirrus Labs images log in as `admin` (password `admin`) with passwordless sudo and SIP disabled. There is no `sshpass` on macOS, so install an ssh key with a short `expect` script, then wrap `ssh`/`scp` in two helper scripts pointing at the VM's IP.

Two things need to be granted to the ssh session before anything visual works. With SIP off, insert rows into `/Library/Application Support/com.apple.TCC/TCC.db` (`client_type` 1, `auth_value` 2) for `kTCCServiceScreenCapture` and `kTCCServiceAccessibility` with clients `/usr/libexec/sshd-session`, `/usr/sbin/sshd` and `/usr/libexec/sshd-keygen-wrapper`, and `kTCCServiceAppleEvents` rows per target bundle id (`com.apple.Safari`, `com.google.Chrome`, `org.mozilla.firefox`). After that `screencapture` and `osascript` with System Events work over ssh. Shrink screenshots with `sips -Z 1400` before reading them.

## The app

A Debug build signed with the development identity runs fine in the VM:

```sh
xcodebuild -scheme Sprinkles -configuration Debug -derivedDataPath build/dd build
ditto -c -k --keepParent build/dd/Build/Products/Debug/Sprinkles.app Sprinkles.zip
# scp it over, then in the VM:
ditto -x -k Sprinkles.zip /Applications/ && open /Applications/Sprinkles.app
```

The app is sandboxed, so its files live in `~/Library/Containers/com.brnbw.Sprinkles/Data` (certificates in `Certs/` there, not `~/Certs`). Drive onboarding with System Events: the buttons are nested in custom views, so search the window's UI elements recursively for a button by name. For the open panel, type the path with Cmd+Shift+G. Keychain trust prompts come from the `SecurityAgent` process: poll for its window, make it frontmost, then type the password. Typing blind is dangerous; stray keystrokes once pressed "Reset certificates" in the Settings window.

Useful checks from the VM shell:

```sh
curl -s https://localhost:3133/version.json          # trusted without -k means the CA is trusted
sudo lsof -nP -iTCP:3133 -sTCP:LISTEN                 # loopback only
curl -skI -H 'Origin: https://evil.example' https://localhost:3133/v3/domains.json   # no ACAO header
curl -skI -H 'Origin: safari-web-extension://x' https://localhost:3133/v3/domains.json # echoed
security dump-trust-settings                          # one Sprinkles cert, SSL policy only
openssl x509 -inform der -in "$C/ca.der" -noout -text # name constraints present
```

## Safari

Enable the extension through Safari › Settings › Extensions (the checkbox is reachable with System Events), then grant it on a site from the toolbar popover. With `defaults write com.apple.Safari AllowJavaScriptFromAppleEvents -bool true` and a Safari restart, `do JavaScript` can read the DOM, for example `document.querySelectorAll('style[data-sprinkles-injected]').length`.

## Chrome

Download the dmg inside the VM. Google-branded Chrome ignores `--load-extension`, so load the unpacked extension through `chrome://extensions`: start Chrome with `--force-renderer-accessibility` so System Events can click "Developer mode", "Load unpacked" and, on the extension's details page, "Allow User Scripts". The service worker only sees `chrome.userScripts` after that toggle plus a worker restart.

For real diagnostics start Chrome with `--remote-debugging-port=9222 "--remote-allow-origins=*"` on a custom `--user-data-dir`, list targets at `localhost:9222/json`, and evaluate in the service worker over the DevTools protocol (a stdlib Python WebSocket client is about 60 lines). That is how the missing offscreen `change` events and the registered scripts were verified. Note that reloading an unpacked extension does not recreate an existing offscreen document.

## Firefox

System Events cannot see Firefox page content, so use Marionette instead:

```sh
firefox --profile /tmp/ffprof --no-remote --marionette --remote-allow-system-access about:blank
```

Marionette listens on `127.0.0.1:2828` with `len:json` framing. `Addon:Install {path, temporary: true}` loads the extension, `Marionette:SetContext chrome` plus `WebDriver:ExecuteScript` with an async IIFE calling `ExtensionPermissions.add(id, {permissions: ["userScripts"], origins: []}, WebExtensionPolicy.getByID(id).extension)` grants the optional permission, and `WebDriver:Navigate`, `GetTitle` and `ExecuteScript` check the result. Put `user_pref("security.enterprise_roots.enabled", true);` in the profile's `user.js` so Firefox trusts the Sprinkles CA from the keychain.

## What to verify

- Fresh onboarding, then the renewal prompt when upgrading from certificates without a `version` marker.
- Reset certificates removes the old CA from the keychain and relaunches into onboarding.
- Each browser applies the global and per-domain files, picks up an edit on the next navigation, keeps scripts registered while the app is quit, and recovers when it comes back.
- Chrome's toolbar icon follows the system appearance.
