# Philips TV Menubar

A native **macOS menu bar** remote for **Philips Titan OS** TVs — launch any TV app
(YouTube, Netflix, Disney+, HBO Max, …), switch HDMI sources, drive Ambilight, and
control an **Orange TV box** on the same network.

> Tested on a **Philips 55PML9019/12** (Titan OS, JointSpace API v6.1, Poland) with an
> **Orange Polska** Sagemcom decoder on HDMI 1 and a Philips soundbar on HDMI 2 (eARC).

Inspired by [LGwebOS-menubar](https://github.com/gabrielgreco1/LGwebOS-menubar).

## Features

| Tab | What it does |
|---|---|
| 🏠 **Home** | TV preview with an Ambilight halo, volume (soundbar via HDMI-CEC), favourite apps (Home is always first), quick sources |
| 🎮 **Remote** | D-pad, OK/Home/Back/Menu/Info, media keys, channel ±, pointer trackpad, keyboard |
| ▦ **Apps** | Every app installed on the TV, with icons, search and ★ favourites — one click launches it |
| ⌁ **Sources** | HDMI 1–4, Satellite, Antenna, Streaming, USB, Network |
| 📦 **Orange TV** | Remote for the Orange decoder: power, d-pad, channels, digits, VOD, record |
| ✨ **Ambilight** | Follow video / follow audio / fixed colour presets, off |
| ⚙️ **Settings** | Connection status, re-pairing, refresh, quit |

## How it works — three control channels

Titan OS locks down the classic JointSpace app/source endpoints
(`/6/applications`, `/6/sources` → **403**). The app combines three channels:

### 1. JointSpace v6 (`https://<tv>:1926/6/…`) — Ambilight, pointer, status
PIN pairing (`/6/pair/request` → PIN on screen → HMAC-SHA1 signature → `/6/pair/grant`),
then HTTP **Digest** auth. Shared key and signature scheme from
[`ha-philipsjs`](https://github.com/danielperna84/ha-philipsjs) (the old `pylips` key
doesn't work on Titan OS). URLSession's built-in digest fails against this TV, so the
`Authorization` header is computed manually.

> ⚠️ Don't call list-dumping endpoints such as `/6/channeldb/tv/channelLists/all` —
> on this TV it hung the JointSpace server until the TV was unplugged.

### 2. Titan OS MQTT (`mqtts://<tv>:8883`) — apps, remote keys, sources
The protocol of the official **Titan OS Mobile** app, reverse-engineered from
`tv.titanos.eos.mobile`:

- **TLS** pinned to the "Titanos Root CA" bundled with the mobile app; no client cert.
- **Pairing**: `pairing/start {"type":"mobile"}` → 4-digit PIN on the TV →
  `pairing/finish {"username","challenge_result": hex(HMAC-SHA256(PIN, challenge))}` →
  MQTT username/password.
- **Launch any app**: `deeplink {"app_code":"disney","url":"disneyplus"}` — codes and
  urls come from the TV's own list (`proxy` → `/v1/me/user_apps`).
- **Remote keys**: `rc {"key_code":N}` (Linux input keycodes, e.g. Home 102, OK 352).
  Keeps working even when JointSpace hangs.
- **Sources**: there is no source API, so the app opens the Sources drawer and walks it:
  `Home → Sources(394) → Down×12 → Up×n → OK` (the list doesn't wrap, so focus is
  pinned to an end first). Screen mirroring is never selected — it drops the TV off
  the network.

### 3. DIAL (`http://<tv>:56789/apps/<Name>`) — fallback without Titan pairing
YouTube, Netflix, Prime Video (`AmazonInstantVideo`) and YouTube Kids. The TV checks a
per-app `Origin` header (e.g. `https://www.youtube.com`) — without it, 403.

### Orange TV box (`http://<box>:8080/remoteControl/cmd`)
Orange Polska's Sagemcom/SoftAtHome decoder speaks the same local API as Orange
France's Livebox boxes, no auth: `operation=10` (status) and
`operation=01&key=<keycode>&mode=0` (key press; digits 512–521 tune by number).
The box has no Wake-on-LAN — if it drops off the network, wake it with its own remote.

## Install (macOS app)

```bash
git clone https://github.com/bedirhanyildirim/philips_tv.git
cd philips_tv/app
./make-signing-cert.sh      # once — stable identity so the Local Network permission sticks
./build.sh
open dist/PhilipsTVMenubar.app
```

Requires macOS 13+ and the Xcode Command Line Tools. On first launch:

1. Allow **Local Network** access (System Settings → Privacy & Security → Local Network).
2. Pair the remote: enter the TV's IP, then the PIN shown on the TV.
3. Pair Titan OS (Apps tab → *Unlock all apps*): enter the second PIN.

Credentials live in `~/.philips-tv-remote/` (`credentials.json`, `titan_mqtt.json`, mode 600)
and are never committed. To start at login: System Settings → General → Login Items.

## Python reference client

```bash
python3 -m pip install -r requirements.txt
python3 pair.py 192.168.0.45          # JointSpace pairing
python3 titan_pair.py 192.168.0.45    # Titan OS MQTT pairing
python3 titan_pair.py --apps          # list installed apps
python3 titan_pair.py --launch disney # launch one
```

## Project layout

```
philips_tv/
├── app/                          # SwiftUI menu bar app (primary)
│   ├── build.sh, make-signing-cert.sh, Package.swift, Resources/Info.plist
│   └── Sources/PhilipsTVMenubar/
│       ├── PhilipsClient.swift   # JointSpace v6 (pairing, manual digest, keys, Ambilight, DIAL)
│       ├── TitanClient.swift     # Titan OS MQTT v5 client (pairing, deeplink, rc, proxy)
│       ├── OrangeClient.swift    # Orange TV box HTTP API
│       ├── AppState.swift        # state, launching, source macro, Orange
│       ├── PhilipsTVApp.swift    # MenuBarExtra, header, tab bar, footer
│       ├── Theme.swift           # cards, buttons, colours
│       └── HomeTab / RemoteTab / AppsTab / SourcesTab / OrangeTab / AmbilightView / SettingsTab
├── philipstv/                    # Python reference client
│   ├── client.py                 # JointSpace v6
│   ├── titan.py, titan_ca.crt    # Titan OS MQTT
│   ├── orange.py                 # Orange TV box
│   └── menubar.py                # legacy rumps menu bar
├── pair.py, titan_pair.py, run.py
├── dns/                          # DNS ad-blocking for Titan Ads
└── ROADMAP.md                    # status, hard-won facts, next steps
```

## Credits / references

- [ha-philipsjs](https://github.com/danielperna84/ha-philipsjs) — JointSpace pairing/signature
- [pylips](https://github.com/eslavnov/pylips) — JointSpace command reference
- Titan OS Mobile app — MQTT protocol (reverse-engineered for interoperability)
- [LGwebOS-menubar](https://github.com/gabrielgreco1/LGwebOS-menubar) — UI inspiration

## License

MIT
