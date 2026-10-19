# Blocking Titan Ads via DNS

Titan OS serves home-screen ads and telemetry from external servers
(**Equativ / Smart AdServer** as the ad SSP, **ThinkAnalytics** for
recommendations). You can't turn these off in the TV UI, but you can stop the
TV from reaching those servers at the **DNS** level — without touching the TV's
firmware and fully reversibly.

## Option A — discover + block with the local sinkhole (best for precision)

`sinkhole.py` is a tiny DNS server that logs every domain the TV looks up and
returns NXDOMAIN for anything in `tv-adblock.txt`, forwarding the rest to a real
resolver so the TV keeps working.

1. Find this Mac's LAN IP (e.g. `192.168.0.204`): `ipconfig getifaddr en0`
2. Run the sinkhole (port 53 needs sudo):
   ```bash
   sudo python3 dns/sinkhole.py
   ```
   (For a quick test without sudo: `PORT=5353 python3 dns/sinkhole.py`, then
   `dig @127.0.0.1 -p 5353 smartadserver.com`.)
3. On the TV: **Settings → Network → (your connection) → IP configuration →
   Manual**, set **DNS** to this Mac's IP. Keep the rest (IP/gateway) as-is.
4. Watch the console. Lines flagged `⚠︎ ad?` are candidates — add the real
   ad/telemetry ones (especially any `*.titanos.tv` ad subdomains) to
   `tv-adblock.txt`, they'll be blocked immediately.
5. Discovered domains are also saved to `dns/discovered-domains.log`.

> The Mac must stay on for the TV to resolve DNS. For an always-on solution use
> Option B.

## Option B — permanent, no always-on Mac (recommended long-term)

Use a hosted or always-on resolver and point the TV's DNS at it:

- **NextDNS** (free tier): create a config, add the domains from
  `tv-adblock.txt` under *Denylist*, optionally add the curated
  [`Okazakee/tv-dns-blocklist`](https://github.com/Okazakee/tv-dns-blocklist),
  then set the TV's DNS to your NextDNS IPs.
- **AdGuard Home / Pi-hole** on an always-on device (Raspberry Pi, NAS, old
  Mac): import `tv-adblock.txt` + the curated list, set it as the TV's DNS
  (or the whole network's via the router).
- **Router DHCP DNS**: point the router's DNS at the above so every device is
  covered.

## Notes

- Keep an **allowlist** for DRM/playback/app-store/update hosts so streaming
  apps keep working. The curated `Okazakee/tv-dns-blocklist` ships one.
- This blocks ad *delivery*; empty ad slots may still show placeholders.
- Everything here is reversible: revert the TV's DNS to automatic to undo.
