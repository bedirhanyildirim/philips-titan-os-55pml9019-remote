# Philips TV Menubar — Roadmap & Context Handoff

> This file is the single source of truth for continuing the project in a new
> chat. It captures what's done, the hard-won technical facts, and what's next.

## What this is

A native **macOS menu bar app** (SwiftUI) to control a **Philips Titan OS TV**
over the local network, plus a Python reference client and DNS ad-blocking tools.
Scope is **TV + Ambilight + soundbar** (not a full smart-home dashboard — the
3D-house reference app by @0xProbabillity was only aesthetic inspiration).

Repo: https://github.com/bedirhanyildirim/philips_tv

## The hardware (this specific setup)

- **TV:** Philips **55PML9019/12** (Titan OS), chassis **TPN248E_V248.010.000.121**
  - IP **192.168.0.45**, MAC **0c:ca:fb:7e:64:b2** (wired Ethernet)
  - Network 192.168.0.0/24, router .1, Mac is 192.168.0.204 (Wi-Fi)
  - JointSpace **API v6.1**, `secured_transport`, `digest_auth_pairing`
  - DRM = **Nagra** (NOT Widevine) → browser-based Spotify won't work
  - **DMR / DLNA is ON** (can receive pushed media), **WoWLAN enabled**
- **Soundbar:** Philips **TAB6309/10** on **HDMI 2** (eARC). TV speakers are OFF →
  volume rides HDMI-CEC to the soundbar.
- **HDMI map:** 1 = "orange box" (likely **Orange Polska** Android-TV decoder, usually off),
  2 = soundbar, 3 = empty (used to wire the Mac here for mirroring), 4 = empty.

## How it works (JointSpace v6)

- Base URL: `https://<ip>:1926/6/...` (self-signed TLS → must accept the cert).
- **Pairing:** `POST /6/pair/request` (body wraps scope in `"access"`, device_id =
  `token_hex(16)`) → TV shows a **PIN (~30s)** → `signature = base64(HMAC-SHA1(sharedKey, timestamp+pin))`
  using **raw digest bytes** → `POST /6/pair/grant` (auth block uses `auth_appId`) with HTTP Digest.
- **Shared key (works on Titan OS, from ha-philipsjs, NOT pylips):**
  `ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA==`
- Credentials saved at `~/.philips-tv-remote/credentials.json` (device_id + auth_key), mode 600.
- Commands use **HTTP Digest** auth with (device_id, auth_key).

## What works (confirmed on the TV)

- **Power:** `GET/POST /6/powerstate`; `input/key` `Standby` toggles.
- **Volume:** keys `VolumeUp`/`VolumeDown`/`Mute` (forwarded to soundbar via CEC).
  `/6/audio/volume` only reflects the dead internal speaker — DON'T use it.
- **Remote keys:** `POST /6/input/key` (CursorUp/Down/Left/Right, Confirm, Back, Home,
  Options, PlayPause, Stop, Next, Previous, Source, …).
- **Keyboard:** `POST /6/input/textentry` `{"textentry":"..."}` — type into focused field.
- **Pointer/trackpad:** `POST /6/input/pointer` `{"x":dx,"y":dy}` (relative).
- **Current activity:** `GET /6/activities/current` (e.g. `{"id":"browser"}`).
- **Ambilight:** `POST /6/ambilight/currentconfiguration`:
  - Video: `{"styleName":"FOLLOW_VIDEO","menuSetting":M}` — M ∈ STANDARD, NATURAL,
    VIVID, GAME, COMFORT, RELAX, SPORTS (CINEMA is NOT accepted).
  - Audio: `{"styleName":"FOLLOW_AUDIO","algorithm":A}` — A ∈ ENERGY_ADAPTIVE_BRIGHTNESS,
    ENERGY_ADAPTIVE_COLORS, VU_METER, SPECTRUM_ANALYZER, KNIGHT_RIDER_CLOCKWISE,
    KNIGHT_RIDER_ALTERNATING, RANDOM_PIXEL_FLASH, STROBE, PARTY. (Uses `algorithm`, not `menuSetting`.)
  - Colour presets: `{"styleName":"FOLLOW_COLOR","menuSetting":C}` — C ∈ HOT_LAVA (red),
    DEEP_WATER (blue), FRESH_NATURE (green), ISF (warm white), PTA_LOUNGE (cool white).
  - Off: `{"styleName":"OFF"}`.
  - NOTE: while app-controlled, the TV's own Ambilight menu shows "Follow App" and
    locks its manual presets — this is expected.

## What's blocked / dead ends (don't re-litigate)

- **`/applications`, `/sources`, `/applicationstore` → 403** on api v1/5/6, GET+POST.
  Firmware ACL, NOT bypassable client-side. So **no direct app launch / HDMI source
  select via the API.** Workaround: send `Source`/`Home` key + navigate with the d-pad.
- **Matter** (added TV to Apple Home via code): Apple Home shows "not supported" —
  no useful controls. Dead end for source/app.
- **Spotify on Titan OS:** not in the store, no sideloading; browser won't work (Nagra DRM).
  Real fix = external HDMI streamer (Chromecast/Google TV, Apple TV, Shield).
- **Mac → TV screen mirroring:** TV's "Screen Mirroring" = **Miracast** (Windows/Android
  only; Mac can't). Options: wired HDMI 3, DLNA file push, or an AirPlay/Chromecast dongle.
  ⚠️ While the TV is in Screen-Mirroring mode it **drops off the network** and the
  JointSpace API is unreachable (ping fails). Exit it to restore control.

## macOS gotchas (critical — cost hours)

1. **Local Network permission:** macOS 15 blocks LAN access until granted
   (error `-1009 "Local network prohibited"`). Needs `NSLocalNetworkUsageDescription`
   (set) AND a **stable code signature** — ad-hoc re-signing on every build resets the
   grant. Fix: `app/make-signing-cert.sh` creates a stable self-signed identity;
   `build.sh` uses it so the permission **persists across rebuilds**. Grant once per Mac.
2. **HTTP Digest:** URLSession's built-in digest auth FAILS against this TV (401).
   We compute the Digest `Authorization` header manually (CryptoKit MD5), matching
   Python `requests`. See `PhilipsClient.digestHeader(...)`.
3. **Swift @MainActor:** `AppState.log` must be `nonisolated` (called from the client's
   background context).

## Project layout

```
philips_tv/
├── ROADMAP.md              ← this file
├── README.md
├── app/                    ← native SwiftUI menu bar app (PRIMARY)
│   ├── Package.swift, build.sh, make-signing-cert.sh
│   ├── Resources/Info.plist   (LSUIElement + NSLocalNetworkUsageDescription)
│   └── Sources/PhilipsTVMenubar/
│       ├── PhilipsClient.swift  (JointSpace v6: pairing, manual digest, commands)
│       ├── AppState.swift       (@MainActor ObservableObject)
│       ├── PhilipsTVApp.swift   (MenuBarExtra + ControlView + Trackpad)
│       └── AmbilightView.swift  (Video/Audio/Colour picker)
├── philipstv/              ← Python reference client (CLI + testing)
├── pair.py, run.py
└── dns/                    ← DNS ad-blocking (sinkhole + blocklist)
```

## Build & run (per Mac)

```bash
git clone https://github.com/bedirhanyildirim/philips_tv.git
cd philips_tv/app
./make-signing-cert.sh      # once — stable identity so Local Network perm sticks
./build.sh
open dist/PhilipsTVMenubar.app
# First launch: grant Local Network when prompted (System Settings → Privacy → Local Network).
# Pair in-app (enter TV IP + on-screen PIN), or: python3 ../pair.py 192.168.0.45
```

## Roadmap (pick up here)

- [ ] **Ambilight custom colour picker (HSB).** `FOLLOW_COLOR`+`MANUAL_HUE` with raw
      `colorSettings{color{hue,saturation,brightness}}` returned 200 but SNAPPED to a
      preset (PTA_LOUNGE). Needs investigation: likely `isExpert:true` + exact
      `colorSettings`/`colorDelta`/`speed` shape. Presets already work.
- [ ] **DLNA "send to TV"** (photo/music/video) — DMR is ON; the working version of the
      "show my own content instead of ads" idea.
- [ ] **UI polish** — glassy/dark aesthetic closer to the reference apps; animations,
      better layout, app icon.
- [ ] **Source switching UX** — `Source` key + d-pad macro (direct select is 403).
- [ ] **Wake-on-LAN** to power the TV on from standby (WoWLAN enabled; MAC known).
- [ ] **Login item / auto-start** (System Settings → Login Items, or a LaunchAgent).
- [ ] **Orange box (HDMI 1)** — if it's an Android-TV Orange Polska decoder: Wake-on-LAN
      (its Menu→Network→Wake on LAN) + network remote (its Network→TV Remote App Settings)
      or ADB. Need its model + IP + enabling those settings on the box.
- [ ] **Official Philips app APK reverse-engineering** — to confirm whether source/app
      control is possible at all (it pairs with the same PIN/JointSpace, so likely at
      parity with us; QR code is just to download the app). Use jadx/REA on the APK.

## Ideas & explored concepts (keep for future chats)

### Screen mirroring (Mac → TV)
- The TV's **"Screen Mirroring" source is Miracast** ("pair your active screen /
  mobile device — works on laptop" = Windows/Android senders). **macOS cannot
  Miracast**, so no native Mac mirroring to this input.
- ⚠️ Entering Screen-Mirroring mode makes the TV **drop off the LAN** → JointSpace
  API unreachable until you exit it. (Explains sudden "can't reach TV" during testing.)
- Options to actually get the Mac on the TV, ranked:
  1. **Wired HDMI 3** (what the user did before) — zero lag, 100% reliable.
  2. **AirPlay/Chromecast dongle** (Apple TV 4K / Chromecast w/ Google TV) — best
     wireless; also solves Spotify + bypasses Titan ads.
  3. **DLNA media push** — DMR is ON; push photo/music/video FILES (not live screen).
     We can build this into the app.
  4. **DLNA screen-mirror apps** (e.g. `mirrorcast-macos`, JustStream, AirParrot) —
     capture the Mac screen and stream over DLNA; works but laggy.
- App feature idea: a "Mirror / Cast" tab that (a) one-tap opens the TV's Screen-
  Mirroring input via key nav, and/or (b) DLNA-pushes a chosen file.

### Orange box (HDMI 1) control
- Almost certainly an **Orange Polska TV decoder**; current models (4K, 4K Stream,
  4K Multi, 4K Duo) run **Android TV** (e.g. 4K Duo = Android TV 14, Amlogic S905X5M).
- Possible control paths IF it's an Android-TV model and on the LAN:
  - **Wake-on-LAN** to power it on (enable on the box: Menu → Network → Wake on LAN).
  - **Network remote** ("Orange Box Remote" — enable on the box: Network → TV Remote
    App Settings).
  - **ADB over TCP** (Android TV) for full control / app launch.
- Needed to proceed: the box's exact **model + IP + MAC**, and enabling the above on
  the box itself. Then integrate as a second device in the app (power via WoL, keys via
  Android TV Remote v2 protocol or ADB).

### "Show my own images instead of ads"
- Redirecting ad DNS to our own server does NOT work: ads are HTTPS (can't forge
  their cert / can't install a custom CA on Titan OS), the ad response must match
  Equativ's exact API schema, and we can't drive the OS home-screen renderer.
- Working alternative = **DLNA push** (show your photos/video as full-screen media),
  or your own page in the TV browser, or an HDMI dongle's home screen.

## DNS ad-blocking (Titan Ads)

Titan Ads = Equativ (ex-Smart AdServer) SSP + ThinkAnalytics. Can't remove in UI;
block at DNS. `dns/sinkhole.py` logs + NXDOMAINs; `dns/tv-adblock.txt` has the hosts.
Permanent: NextDNS/AdGuard/Pi-hole as the TV's DNS. See `dns/README.md`.

## Continuing from a phone

`/rc` in Claude Code → scan QR with the Claude app (Max tier) to drive this session;
or cloud sessions at claude.ai/code / the Claude app's Code tab.
