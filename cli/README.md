# Sprinkles for Linux (CLI)

A command-line version of the Sprinkles Mac app. It serves your per-domain CSS
and JavaScript at `https://localhost:3133` with the same API as the Mac app, so
the existing Chrome and Firefox extensions work unchanged.

## Install

```sh
cd cli
go build -o sprinkles .
./sprinkles install    # copies itself to ~/.local/bin and starts on login
```

`install` copies the binary to `~/.local/bin/sprinkles`, writes a systemd user
service (`~/.config/systemd/user/sprinkles.service`), then enables and starts
it. Run it again after rebuilding to update. `sprinkles uninstall` removes the
service.

It needs Go 1.26+ (see `mise.toml`). `sprinkles trust` needs `certutil`
(Arch: `nss`, Debian/Ubuntu: `libnss3-tools`).

## Usage

Run `sprinkles` in a terminal for the dashboard:

```
Sprinkles 1.2.1

  Server    ● Serving https://localhost:3133 · systemd service
  Scripts   ~/Sprinkles · 4 domains
  Config    ~/.config/sprinkles/config.json
  CA        trusted in all 2 browser profiles · expires 2036-09-25
  Service   enabled · starts on login

  Log
  11:39:56 GET /v3/domains.json
  11:39:56 GET /v3/s/example.com.js

  s stop · r restart · o open scripts · d change dir · e edit config · l log file
  t trust in browsers · T trust system-wide · u untrust · i reinstall service
  x remove service · q quit (server keeps running)
```

The server runs as a separate background process. The dashboard only talks to
it (over `$XDG_RUNTIME_DIR/sprinkles.sock`), starting it if needed, and the
server keeps running when you quit. Without the service installed, the server
runs until you log out, and its output goes to
`~/.local/state/sprinkles/sprinkles.log`.

Setting up without the dashboard:

```sh
sprinkles setup ~/Sprinkles   # choose the scripts dir, create certificates, trust the CA
sprinkles install             # or `sprinkles start` to run until logout
```

## Scripts

Name files after the domain: `example.com.css`, `sub.example.com.js`.
`global.css` and `global.js` apply to every site. The extension reloads its
scripts when files change.

`setup` and the dashboard also create a local certificate authority plus a
`localhost` certificate in `~/.local/share/sprinkles/certs`, and add the CA to
your browsers' NSS databases: Chromium-based browsers use `~/.pki/nssdb`;
Firefox, LibreWolf, Zen and others use their profile dirs, including Flatpak
and Snap installs. Restart the browser afterwards.

## Commands

```
sprinkles                      # dashboard (in a terminal)
sprinkles install | uninstall  # systemd user service, starts on login
sprinkles start | stop | restart
sprinkles logs                 # follow the server log
sprinkles status
sprinkles setup [DIR]
sprinkles trust [--system]     # add the CA to browsers (--system: OS trust store too, via sudo)
sprinkles untrust [--system]
sprinkles serve [--dir DIR] [--port 3133] [--host localhost] [--http] [-v]   # foreground
sprinkles version
```

Config changes made with `setup`, or in the dashboard, apply to the running
server immediately. `SPRINKLES_DIR` and `SPRINKLES_PORT` override the config
file.

## API

| Route                   | Response                                             |
| ----------------------- | ---------------------------------------------------- |
| `GET /v3/domains.json`  | Domains that have a `.js` or `.css` file             |
| `GET /v3/checksum.json` | `{"checksum": n}`, which changes when any file changes |
| `GET /v3/s/<domain>.js` | The domain's JS, with its CSS injected as a `<style>` |
| `GET /s/<domain>.js`    | Legacy: `global` followed by the domain              |
| `GET /version.json`     | `{"version", "build"}`                               |
