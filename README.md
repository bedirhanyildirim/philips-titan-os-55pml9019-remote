# Philips TV Menubar

A native **macOS menu bar** remote for **Philips Titan OS** TVs, controlled over
the local network via the TV's JointSpace v6 API.

Inspired by [LGwebOS-menubar](https://github.com/gabrielgreco1/LGwebOS-menubar)
(which targets LG webOS) — this project re-implements the idea for Philips TVs
running **Titan OS**, where the connection layer is JointSpace v6 (HTTPS + PIN
digest pairing) instead of LG's SSAP.

> Tested on a **Philips 55PML9019/12** (Titan OS, JointSpace API v6.1).

## Features

- ⏻ Power on/off
- 🔊 Volume up / down / mute — forwarded to an HDMI-ARC soundbar via CEC
- 🎮 D-pad, OK, Back, Home, Options, Info
- ⏯ Media transport (play/pause, stop, next/prev, seek)
- 📡 Source switching
- 🎨 **Ambilight** control (follow video / follow audio / off) — Philips-specific bonus

## How it works

Philips Titan OS TVs expose the JointSpace v6 API on `https://<tv-ip>:1926/6/...`.
Control requires a one-time **PIN pairing**:

1. `POST /6/pair/request` → the TV shows a PIN, returns an `auth_key` + `timestamp`
2. `signature = base64( HMAC-SHA1(shared_key, timestamp + pin) )`
3. `POST /6/pair/grant` (HTTP Digest auth) → pairing confirmed
4. Every later request uses HTTP Digest auth with `device_id` + `auth_key`

The shared key and signature scheme match
[`ha-philipsjs`](https://github.com/elupus/ha-philipsjs) (used by Home Assistant),
which is the implementation that works on current Titan OS firmware. The older
`pylips` key does **not** work on these TVs.

> **Note on audio:** when a soundbar is connected over HDMI-ARC/eARC, the TV's own
> speaker level (`/6/audio/volume`) is inert. Volume is driven with the
> `VolumeUp` / `VolumeDown` / `Mute` **keys**, which the TV relays to the soundbar
> over HDMI-CEC.

## Native macOS app (SwiftUI) — recommended

A polished menu bar app lives in [`app/`](app/) (SwiftUI, `MenuBarExtra`).
Dark glassy popover with power, volume, d-pad, media, Ambilight styles, a
**keyboard** field and a **trackpad** for the TV browser.

Install on each Mac:

```bash
git clone https://github.com/bedirhanyildirim/philips_tv.git
cd philips_tv/app
./build.sh
open dist/PhilipsTVMenubar.app
```

Requires the Xcode Command Line Tools (`xcode-select --install`) and macOS 13+.
First launch shows a pairing screen (enter the TV's IP, then the on-screen PIN).
Credentials are stored per-Mac in `~/.philips-tv-remote/credentials.json`.

To auto-start it at login: System Settings → General → Login Items → add
`PhilipsTVMenubar.app`.

## Python CLI / tools

The `philipstv/` package is the reference client (also used for DNS tooling).

```bash
git clone https://github.com/bedirhanyildirim/philips_tv.git
cd philips_tv
python3 -m pip install -r requirements.txt
```

## Usage

1. **Find your TV's IP** (router, or it's the device with port 1925/1926 open).
2. **Pair** (TV must be ON; a PIN appears on screen):

   ```bash
   python3 pair.py 192.168.0.45
   ```

3. **Run the menu bar app**:

   ```bash
   python3 run.py
   ```

Credentials are stored locally in `~/.philips-tv-remote/credentials.json`
(mode `600`) and are **never** committed.

## Project layout

```
philips_tv/
├── pair.py                 # one-time PIN pairing CLI
├── run.py                  # launches the menu bar app
├── requirements.txt
└── philipstv/
    ├── client.py           # JointSpace v6 client (pairing + commands)
    └── menubar.py          # rumps menu bar UI
```

## Credits / references

- [ha-philipsjs](https://github.com/elupus/ha-philipsjs) — pairing/signature reference
- [pylips](https://github.com/eslavnov/pylips) — JointSpace command reference
- [LGwebOS-menubar](https://github.com/gabrielgreco1/LGwebOS-menubar) — UI inspiration

## License

MIT
