# Philips TV Menubar — Roadmap & Context Handoff

> This file is the single source of truth for continuing the project in a new
> chat. It captures what's done, the hard-won technical facts, and what's next.

## What this is

A native **macOS menu bar app** (SwiftUI) to control a **Philips Titan OS TV**
over the local network — apps, sources, remote, Ambilight — plus the **Orange TV box**
on HDMI 1, a Python reference client and DNS ad-blocking tools.

Repo: https://github.com/bedirhanyildirim/philips-titan-os-55pml9019-remote

## The hardware (this specific setup)

- **TV:** Philips **55PML9019/12** (Titan OS), chassis **TPN248E_V248.010.000.121**
  - IP **192.168.0.45**, MAC **0c:ca:fb:7e:64:b2** (wired Ethernet)
  - Network 192.168.0.0/24, router .1, Mac is 192.168.0.204 (Wi-Fi)
  - JointSpace **API v6.1**, `secured_transport`, `digest_auth_pairing`
  - DRM = **Nagra** (NOT Widevine) → browser-based Spotify won't work
  - **DMR / DLNA is ON** (can receive pushed media), **WoWLAN enabled**
- **Soundbar:** Philips **TAB6309/10** on **HDMI 2** (eARC). TV speakers are OFF →
  volume rides HDMI-CEC to the soundbar.
- **HDMI map:** 1 = **Orange Polska decoder** ("Orange TV Dekoder (Sagemcom)", IP
  **192.168.0.244**, MAC b0:5b:99:c2:0b:35, Ethernet), 2 = soundbar ("Home Theatre System"),
  3 = "Computer" (empty), 4 = empty.
- **TV account:** user is logged into a Titan OS account (bedirhanyildirim96@gmail.com);
  not needed for control.

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
- **Ambilight power:** `POST /6/ambilight/power {"power":"Off"|"On"}` (styleName OFF is
  accepted but doesn't turn lights off). ⚠️ Power Off is ALSO ignored physically on this TV
  (API says Off, lights stay on) — open issue, see roadmap.
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

## Titan OS MQTT (:8883) — the real control channel (2026-10-20)

Reverse-engineered from the official **Titan OS Mobile** app (`tv.titanos.eos.mobile` 1.4.4).
- MQTT **v5 over TLS** on 8883; server cert chains to **"Titanos Root CA"** (bundled in
  `philipstv/titan_ca.crt` and embedded in `TitanClient.swift`); no client cert, no hostname check.
  mDNS: `_secure-mqtt._tcp`. Retained `info` topic lists supported topics.
- **Pairing:** anonymous connect → request `pairing/start` `{"type":"mobile"}` (lowercase!)
  → TV shows 4-digit PIN → `pairing/finish` `{"username":<uuid>,"challenge_result":
  hex(HMAC-SHA256(key=PIN, msg=challenge))}` → `{"data":{"password":…}}`.
  Creds: `~/.philips-tv-remote/titan_mqtt.json`.
- **Request pattern:** subscribe `<topic>/<uuid>`, PUBLISH to `<topic>` with MQTT5
  ResponseTopic + CorrelationData = that string; reply `{"data":…}` / `{"error":{code,message}}`.
- **Launch apps:** `deeplink` `{"app_code":"disney","url":"disneyplus"}` — this TV offers
  `deeplink` (v1), not `deeplink_v2`. Codes/urls from `proxy` → `/v1/me/user_apps`.
  Verified: YouTube, Netflix, Prime, Disney+, HBO Max (`max`, `https://titan.play.max.com`),
  tabii, Internet browser. ⚠️ A non-special app_code + `localfunction:` url → Chromium
  "blocked" page.
- **Remote keys:** `rc` `{"key_code":N}` Linux keycodes (Home 102, OK 352, Back 158,
  arrows 103/108/105/106, Vol 115/114, Mute 113, Power 116, Sources 394, KEY_TV 377 =
  last tuner). Works even when JointSpace hangs. **Keyboard:** `keyboard` `{"opcode":0,"text":"a"}`.
- **Account API via TV:** `proxy` `{"endpoint":"/v1/me/favorites"|"/v1/me/watchlists"|…,
  "method":"GET","authenticated":true,"api":"gaea", …}` — favourites/watchlist readable.
- `settings` only has tvname/wowlan get/set; `automation/set`, `screenshot` don't reply.
- **`channels/state`** (retained): `"launcher"` on Home, `"inactive"` otherwise.

## Sources (HDMI) — Sources-drawer macro over MQTT `rc`

No API for inputs (`/6/sources*` 403, nothing in MQTT). Drawer is a vertical list:
0 Satellite, 1 Antenna, 2 Streaming, **3 Screen mirroring (never OK!)**, 4 USB, 5 Network,
6 HDMI1 Orange, 7 HDMI2 Home Theatre, 8 HDMI3 Computer, 9 HDMI4. Focus opens on the
**current** source; the list **doesn't wrap** (verified both ends). Macro:
`Home(wait 2s) → 394(wait 2s) → Down×12 → Up×n → OK` for HDMI (n = 3,2,1,0), or
`Up×12 → Down×n` for Satellite/Antenna; ~0.4 s between arrows. Verified on HDMI 1/3/4.
Context after: `WatchExtension` (any HDMI), `WatchSatellite`, `NetTv` (home/apps).
Can't tell which HDMI port is active.

## DIAL (:56789) — fallback without Titan pairing

`POST http://<tv>:56789/apps/<Name>` with per-app **Origin** (else 403):
YouTube/YouTubeKids → `https://www.youtube.com`, Netflix → `https://www.netflix.com`,
`AmazonInstantVideo` → no Origin needed. Disney+/Max aren't DIAL apps.

## Orange TV box (192.168.0.244)

Sagemcom, SoftAtHome 1.7.19, Polish-only UI (no menu language option — only audio
"Wersja językowa" and subtitles). Same local API as Orange France Livebox decoders, no auth:
- `GET :8080/remoteControl/cmd?operation=10` → `activeStandbyState` ("0" on, "1" standby),
  `osdContext` (HOMEPAGE/LIVE/MYACCOUNT…), `playedMediaId` (channel id; 14135 = TVP1).
- `operation=01&key=<code>&mode=0` → keys (same Linux codes; CH± 402/403, digits 512–521,
  menu 139). Verified: arrows, Back, OK, Menu, CH+, digit 1.
- `operation=09&epg_id=…` (France-style tune by id) → invalid / hangs here. Use digits.
- ⚠️ `wolSupport: "0"`. Sending Power (116) while it was in standby made it drop off the
  network entirely — only its own remote brings it back. Power from the app is untested.
- **Power sync works (2026-10-20):** powering the Orange box on also turned the TV on, and
  powering it off turned the TV off — the user enabled HDMI-CEC on the box
  (Moje konto → Ustawienia → HDMI-CEC → CEC włączony). Box stays reachable in
  standby (`activeStandbyState: "1"`, `osdContext: MAIN_PROCESS`). This was done with the
  **app's Orange Power button** (verified by the user). Powering the box on also
  switches the TV to HDMI 1 and live TV (TVP1) comes up — verified.

## What's blocked / dead ends (don't re-litigate)

- **JointSpace `/applications`, `/sources`, `/applicationstore`, `/apps`, `/favoritelist`
  → 403**; `activities/launch` → 405. Use Titan MQTT / DIAL instead (see above).
- `POST /6/activities/browser {"url":…}` → 200 but does nothing visible (not a URL opener).
- Unknown JointSpace key names always return 200 — no Netflix/Disney key exists.
- Philips "Smart TV" Android app (com.tpvision.philipstvapp2): no Titan app launching.
- **`/6/channeldb/*` and big `menuitems/*` dumps hang JointSpace** → TV must be unplugged.
- Second JointSpace failure mode (2026-10-20, after a Wake-on-LAN wake): the web server answers
  instantly but **every** path (even `/6/system`, any API version, :1925 too) returns 404 —
  the backend isn't registered. MQTT/DIAL keep working. Only a TV restart restores it. The app
  now treats "JointSpace down but MQTT up" as TV on.
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
4. **First launch after a rebuild** briefly fails with "Local network prohibited";
   `AppState.startup()` retries. Plain-HTTP to LAN needs `NSAllowsLocalNetworking` (set).

## Project layout

```
philips-titan-os-55pml9019-remote/
├── ROADMAP.md              ← this file
├── README.md
├── app/                    ← native SwiftUI menu bar app (PRIMARY)
│   ├── Package.swift, build.sh, make-signing-cert.sh
│   ├── Resources/Info.plist   (LSUIElement + NSLocalNetworkUsageDescription)
│   └── Sources/PhilipsTVMenubar/
│       ├── PhilipsClient.swift  (JointSpace v6: pairing, manual digest, keys, Ambilight, DIAL)
│       ├── TitanClient.swift    (Titan OS MQTT v5 — hand-rolled on Network.framework)
│       ├── OrangeClient.swift   (Orange box HTTP API)
│       ├── AppState.swift       (@MainActor state; launch, key routing, source macro, Orange)
│       ├── PhilipsTVApp.swift   (MenuBarExtra, header, 7-tab bar, footer)
│       ├── Theme.swift          (cards/buttons)
│       └── HomeTab, RemoteTab, AppsTab, SourcesTab, OrangeTab, AmbilightView, SettingsTab
├── philipstv/              ← Python reference client (client.py, titan.py, orange.py)
├── pair.py, titan_pair.py, run.py
└── dns/                    ← DNS ad-blocking (sinkhole + blocklist)
```

## Build & run (per Mac)

```bash
git clone https://github.com/bedirhanyildirim/philips-titan-os-55pml9019-remote.git
cd philips-titan-os-55pml9019-remote/app
./make-signing-cert.sh      # once — stable identity so Local Network perm sticks
./build.sh
open dist/PhilipsTVMenubar.app
# First launch: grant Local Network when prompted (System Settings → Privacy → Local Network).
# Pair in-app (enter TV IP + on-screen PIN), or: python3 ../pair.py 192.168.0.45
```

## Roadmap (pick up here)

- [x] **Ambilight Off** — fixed: Titan ignores `ambilight/power`, `styleName OFF` and the
      AmbilightOnOff key. The official app sets menu node 300 "Ambilight style" →
      `POST menuitems/settings/update {"values":[{"value":{"Nodeid":300,"Controllable":true,
      "Available":true,"string_id":"MLM_PHM_KEY_MAIN_AMBILIGHT_STYLE","data":{"activenode_id":310}}}]}`
      (310 Off, 320 Follow video, 330 Follow audio, 340 Follow colour, 360 Follow app), then
      `currentconfiguration` for the mode. Verified on/off (HA core #156776). Note: Titan's
      JointSpace HTTPS server wedges under bursts — keep ~1.5 s+ between calls.
- [ ] **Spotify** (must do): not in the Titan catalog in any market (expected "later 2026" —
      re-check `https://app.titanos.tv/v1/apps/spotify?market=pl&device=tv&firmware=x&model=55PML9019%2F12&locale=pl`;
      then launch via MQTT deeplink). TV is not a Spotify Connect / AirPlay target (no mDNS).
      Try both: (1) **DTS Play-Fi** on the TV (Settings → Play-Fi; Music page, Play-Fi port 10109):
      install Philips "Wi-Fi Music"/DTS Play-Fi app on the iPhone, pick "Play-Fi TV" (Play-Fi
      supports Spotify Connect); (2) **AirConnect** (github.com/philippe44/AirConnect, airupnp)
      on the Mac to expose the TV's DLNA renderer as an AirPlay target (needs user OK to run it).
      Fallback: Bluetooth to the TAB6309 soundbar.
- [x] **YouTube control** — Lounge API (`YouTubeLounge.swift`): DIAL screenId → lounge token
      → bind/long-poll; now playing + play/pause/seek verified. Never send `TYPE=terminate`
      (it kicks the TV out of the video). next/previous/playVideo untested.
- [x] **Live "now on"** — context level1 + MQTT `channels/state` + DIAL states (8 s poll).
      Disney+/Max opened from the TV remote show as "An app".
- [~] **Power state when the TV is off** — the app now polls every 15 s and shows "TV off"
      when the TV is unreachable (deep standby, e.g. after the Orange box turns it off via
      CEC: the TV drops off the network). Still open: in *quick* standby (TV remote off)
      `GET /6/powerstate` keeps returning `"On"` (JointSpace keeps running). MQTT `state/power` had no retained
      message; `channels/state` read `{"state":"inactive"}`. Find a reliable signal (e.g.
      subscribe to `state/power` and watch it change on power toggle, `context`, ambilight
      processed values) and poll it periodically in the app.
- [ ] **Pointer (trackpad) + keyboard don't work** (user report, 2026-10-20). Keyboard now
      goes over MQTT `keyboard {"opcode":0,"text":<char>}` — verify the payload (maybe whole
      string / needs a focused field); pointer still uses JointSpace `input/pointer` — check
      if Titan ignores it outside the browser.
- [ ] **Orange channel list** — no public id↔name source (Orange TV Go `gpapi2/live/channel/all`
      needs login; Orange France's woopic API rejects PL). Use the official numbered list
      instead: PDF https://www.orange.pl/medias/omni/lp/b2c/tv/tv_mobilna/Lista-kana%C5%82%C3%B3w-TV-w-technologii-IPTV.pdf
      (257 channels: number, name, HD, category, package; logos matchable via iptv-org).
      Add a searchable logo list to the Orange tab that tunes with digit keys.
- [x] **Orange power** — the app's Power button toggles the box and, via CEC, the TV; the box
      stays on the network in standby. (The very first press, before CEC was on, dropped the
      box off the network — watch for it.)
- [x] Box power-on switches the TV to HDMI 1 (CEC) — verified.
- [ ] UI: make Orange Power the one-tap "Watch Orange" (on Home + Sources); the
      "Show on TV (HDMI 1)" drawer macro is then only needed when the box is already on.
- [ ] Verify guessed rc keycodes on the TV: Next 163, Previous 165, FF 208, Rewind 168, Info 358.
- [ ] **Watchlist/favourites UI** via Titan `proxy` (`/v1/me/watchlists` POST/DELETE with
      `content_id`, `/v1/contents/{id}/deeplinkings` to open a show in its app).
- [x] App launching (any app) — Titan MQTT `deeplink` + DIAL fallback.
- [x] Source switching — Sources-drawer macro (Sources tab).
- [x] UI redesign — tabbed layout, English UI.

- [ ] **Ambilight custom colour picker (HSB).** `FOLLOW_COLOR`+`MANUAL_HUE` with raw
      `colorSettings{color{hue,saturation,brightness}}` returned 200 but SNAPPED to a
      preset (PTA_LOUNGE). Needs investigation: likely `isExpert:true` + exact
      `colorSettings`/`colorDelta`/`speed` shape. Presets already work.
- [ ] **DLNA "send to TV"** (photo/music/video) — DMR is ON; the working version of the
      "show my own content instead of ads" idea.
- [ ] **UI polish** — app icon, animations.
- [x] **Wake-on-LAN** — verified 2026-10-20: a magic packet to 0c:ca:fb:7e:64:b2 /
      38:1b:9e:be:3e:86 (broadcast :9) brings the TV back from deep standby (off the
      network) to fully on within ~5 s. The app's power button sends it when the TV is
      off/unreachable (`WakeOnLAN.swift`). Titan MQTT `settings` has `wowlan.get/set`.
- [ ] **Login item / auto-start** (System Settings → Login Items, or a LaunchAgent).
- [x] **Orange box (HDMI 1)** — found on the LAN; local HTTP remote API works (Orange tab).
- [x] **APK reverse-engineering** — Philips Smart TV app (dead end) and Titan OS Mobile
      (→ MQTT protocol) analysed with jadx.

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
- Done — it's a Sagemcom/SoftAtHome box (not Android TV), see "Orange TV box" above.
- Idea: enable HDMI-CEC on the box (Moje konto → Ustawienia → HDMI-CEC) and EasyLink on
  the TV so powering the box auto-switches the TV to HDMI 1.

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
