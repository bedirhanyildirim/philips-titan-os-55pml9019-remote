# Philips Titan OS local control API — developer reference

Everything we found while building a remote for a **Philips 55PML9019/12** running
**Titan OS** (firmware 248.010.000.121, JointSpace API 6.1). If you're writing a Home
Assistant integration, a Homey/openHAB binding, a remote app or a script for a Philips
Titan OS TV, start here.

**TL;DR** — Titan OS blocks the classic JointSpace app and source endpoints (`403`), but
the TV runs three other local servers. Use the right one for each job:

| Job | Channel | Port | Auth |
|---|---|---|---|
| Launch **any** app (Netflix, Disney+, HBO Max, YouTube, …) | Titan OS MQTT `deeplink` | 8883 (MQTT v5 / TLS) | PIN pairing |
| Remote keys, keyboard | Titan OS MQTT `rc` / `keyboard` | 8883 | PIN pairing |
| Installed apps, Titan account data | Titan OS MQTT `proxy` | 8883 | PIN pairing |
| Ambilight, pointer, system info | JointSpace v6 | 1926 (HTTPS) | PIN pairing + Digest |
| YouTube / Netflix / Prime without pairing | DIAL | 56789 (HTTP) | `Origin` header |
| YouTube now-playing & playback control | YouTube Lounge API | cloud (via DIAL screenId) | none |
| Power on from deep standby | Wake-on-LAN | UDP 9 | — |

Open ports seen on the TV: 1925, 1926 (JointSpace), 8883 (Titan MQTT), 9013, 10108–10120,
10109 (DTS Play-Fi), 49152/49153 (UPnP DMR), 56789/56790 (DIAL), 58012.

---

## 1. Titan OS MQTT (port 8883) — the real control channel

This is the protocol of the official **Titan OS Mobile** app (`tv.titanos.eos.mobile`).

- **Transport:** MQTT **v5** over **TLS**. The server certificate (`CN=TitanOS TV Server`) chains
  to **"Titanos Root CA"** (C=ES, O=TitanOS; SHA-256
  `BC:91:11:1A:19:E8:21:6E:14:59:58:2C:CC:97:74:55:74:FC:7C:5F:85:8C:DE:54:AA:1B:7C:26:C8:0D:DE:DA`),
  bundled here as [`philipstv/titan_ca.crt`](../philipstv/titan_ca.crt). No client certificate.
  Don't check the hostname (connect by IP). mDNS: `_secure-mqtt._tcp`.
- **Client id:** `eos-<username>`. QoS 0, keepalive 30.
- **Discovery of features:** subscribe to the retained `info` topic →
  `{"mqttv_version":"v2.11.3","mqttv_topics":["keyboard","rc","deeplink","pairing/start",
  "pairing/finish","pairing/cancel","proxy","settings","screenshot","screencast",…],
  "fw_version":…,"model":"55PML9019/12","eth_mac_addr":…,"wlan_mac_addr":…,"market":"PL"}`.

### Request / response pattern
1. Subscribe to `<topic>/<random-uuid>`.
2. PUBLISH to `<topic>` with MQTT5 properties **ResponseTopic** = `<topic>/<uuid>` and
   **CorrelationData** = the same string.
3. The reply arrives on the response topic: `{"data": …}` or `{"error": {"code": N, "message": "…"}}`.

### Pairing
1. Connect **anonymously**.
2. Request `pairing/start` with `{"type": "mobile"}` (**lowercase** — `"MOBILE"` gives
   `code 10 Invalid message format`). Reply: `{"data":{"challenge":"…","timeout":60,"attempts":3}}`.
   The TV shows a 4-digit PIN.
3. Request `pairing/finish` with
   `{"username": "<any uuid>", "challenge_result": hex(HMAC-SHA256(key = PIN, msg = challenge))}`.
   Reply: `{"data":{"username":"…","password":"…"}}`.
4. Reconnect with that username/password.

### Launch an app
```json
topic: deeplink
{"app_code": "disney", "url": "disneyplus"}
```
Get `app_code`/`url` for every installed app from the TV itself:
```json
topic: proxy
{"endpoint": "/v1/me/user_apps", "method": "GET", "headers": {},
 "query_params": {"page": "1", "per_page": "50"}, "authenticated": true, "api": "gaea"}
```
Examples (PL market): `youtube` → `https://www.youtube.com/tv`, `netflix` →
`localfunction:gotonetflix`, `prime_video` → `localfunction:gotoaiv`, `disney` → `disneyplus`,
`max` → `https://titan.play.max.com`, `internet_browser` → `localfunction:gotoopeninternet`.
Newer TVs may offer `deeplink_v2` `{"app_code","type","resolution","url"}` — check `info`.

> ⚠️ An arbitrary `app_code` with a `localfunction:` url opens Chromium's "blocked" page.

### Remote keys & keyboard
```json
topic: rc        {"key_code": 102}
topic: keyboard  {"opcode": 0, "text": "a"}      (opcode 1 = backspace)
```
Linux input keycodes: OK 352, Back 158, Home 102, Up 103, Down 108, Left 105, Right 106,
Vol+ 115, Vol− 114, Mute 113, Power 116, Play 207, Pause 119, Play/Pause 164, Stop 128,
Options 357, Quick menu 139, **Sources 394**, TV guide 365, Ch+ 402, Ch− 403,
Red/Green/Yellow/Blue 398–401, **KEY_TV 377** (jump to the last tuner).

### Other topics
- `channels/state` (retained): `{"state":"launcher"}` on the home screen, `"inactive"` when an
  app or another source is in front — the best "am I on the home screen" signal.
- `settings`: only `tvname.get/set` and `wowlan.get/set` (others → `code 14 Operation not implemented`).
- `proxy` also reaches `/v1/me/favorites`, `/v1/me/watchlists`, `/v1/contents/{id}`, `/v1/epg`, …
- `automation/set`, `screenshot`: no reply for a mobile-paired client.

### Selecting HDMI / sources
There is no source API (JointSpace `/6/sources` → 403; nothing in MQTT). What works is walking
the Sources drawer with `rc`. On this TV the drawer is vertical: Satellite, Antenna, Streaming,
**Screen mirroring**, USB, Network, HDMI 1–4. Focus opens on the current source and the list
doesn't wrap, so pin focus to an end first:
`Home (wait 2 s) → Sources 394 (wait 2 s) → Down ×12 → Up ×n → OK` (n = 0 for HDMI 4, 1 for HDMI 3, …).
Never press OK on Screen mirroring — Miracast mode drops the TV off the network.

## 2. JointSpace v6 (port 1926) — Ambilight, pointer, info

- Pairing: `POST /6/pair/request` → PIN → `POST /6/pair/grant` with
  `auth_signature = base64(HMAC-SHA1(shared_key, timestamp + pin))`, shared key from
  [ha-philipsjs](https://github.com/danielperna84/ha-philipsjs). Then HTTP **Digest** auth.
- **Blocked on Titan OS:** `/6/applications`, `/6/apps`, `/6/sources`, `/6/favoritelist` → 403;
  `/6/activities/launch` → 405. `POST /6/activities/browser {"url":…}` → 200 but does nothing.
- `GET /6/context` → `level1`: `NetTv` (home/apps), `WatchExtension` (any HDMI), `WatchSatellite`, …
- `GET /6/powerstate` returns `"On"` even in quick standby.

### Turning Ambilight off (the only way that works on Titan OS)
`ambilight/power Off`, `currentconfiguration {"styleName":"OFF"}` and the `AmbilightOnOff` key
are accepted (`200`) but **ignored**. Set the "Ambilight style" settings node instead:
```json
POST /6/menuitems/settings/update
{"values":[{"value":{"Nodeid":300,"Controllable":true,"Available":true,
  "string_id":"MLM_PHM_KEY_MAIN_AMBILIGHT_STYLE","data":{"activenode_id":310}}}]}
```
Children of node 300: **310 Off**, 320 Follow video, 330 Follow audio, 340 Follow colour,
360 Follow app. To turn it back on, set 320/330/340 and then
`POST /6/ambilight/currentconfiguration {"styleName":"FOLLOW_VIDEO","isExpert":false,"menuSetting":"NATURAL"}`.
Check node ids on your TV with `POST /6/menuitems/settings/current {"nodes":[{"nodeid":300}]}`.

### ⚠️ Stability
- Titan's JointSpace HTTPS server **wedges** under bursts of requests and on big list dumps
  (`/6/channeldb/tv/channelLists/all` hung it until the TV was unplugged). Space calls out.
- Second failure mode: after a Wake-on-LAN wake the server answered **404 to every path**
  (backend not registered) while MQTT and DIAL kept working.

## 3. DIAL (port 56789)

`GET http://<tv>:56789/apps/<Name>` → state; `POST` launches. Registered apps: `YouTube`,
`YouTubeKids`, `Netflix`, `AmazonInstantVideo`. The TV enforces a per-app **Origin**:
YouTube → `https://www.youtube.com`, Netflix → `https://www.netflix.com`, Prime → none.
Without it: `403`. Device description: `http://<tv>:56790/dd.xml`.

## 4. YouTube Lounge API

`GET /apps/YouTube` (DIAL) contains `<screenId>`. Exchange it for a lounge token with
`POST https://www.youtube.com/api/lounge/pairing/get_lounge_token_batch` (`screen_ids=…`),
bind `https://www.youtube.com/api/lounge/bc/bind`, long-poll for `nowPlaying` /
`onStateChange`, and send `play`, `pause`, `seekTo`, `next`, `previous`, `setPlaylist`.
Never send `TYPE=terminate` — it kicks the TV out of the video. See
[`YouTubeLounge.swift`](../app/Sources/PhilipsTVMenubar/YouTubeLounge.swift).

## 5. Power

In deep standby (e.g. switched off over HDMI-CEC) the TV leaves the network. A **Wake-on-LAN**
magic packet to its Ethernet or Wi-Fi MAC (both in the MQTT `info` topic) powers it fully on
in ~5 s. `rc {"key_code":116}` is the Power key.

## Not supported on this model
Google Cast, AirPlay (2024 range), Spotify app (not in the Titan catalog yet; the TV's DTS Play-Fi
receiver is a possible route for Spotify audio — untested).
