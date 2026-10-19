#!/usr/bin/env python3
"""
Tiny DNS sinkhole + logger for discovering and blocking Smart-TV ads.

Point your TV's DNS at the machine running this (TV network settings ->
manual DNS -> this Mac's LAN IP). Every domain the TV looks up is logged;
domains matching the blocklist get NXDOMAIN, everything else is forwarded
to a real upstream resolver so the TV keeps working.

Run (needs port 53 -> sudo):
    sudo python3 sinkhole.py

Then watch which domains the TV hits. Add the ad/telemetry ones to
tv-adblock.txt. For a permanent, always-on setup use NextDNS or AdGuard
Home with the same blocklist (see README).

Options via env:
    PORT=5353        listen on a non-privileged port (for testing)
    UPSTREAM=1.1.1.1 upstream resolver
    BLOCKLIST=path   blocklist file (default: ./tv-adblock.txt)
"""

import os
import socket
import struct
import time
from pathlib import Path

PORT = int(os.environ.get("PORT", "53"))
UPSTREAM = (os.environ.get("UPSTREAM", "1.1.1.1"), 53)
BLOCKLIST_PATH = Path(os.environ.get("BLOCKLIST", Path(__file__).parent / "tv-adblock.txt"))
LOG_PATH = Path(__file__).parent / "discovered-domains.log"

# Heuristic hints to flag likely ad/telemetry domains in the live log.
AD_HINTS = ("ad", "ads", "advert", "analytic", "telemetr", "track", "metric",
            "smartadserver", "sascdn", "equativ", "doubleclick", "thinkanalytics",
            "titanos", "nettvservices", "pubads", "beacon", "collect", "stats")


def load_blocklist():
    domains = set()
    if BLOCKLIST_PATH.exists():
        for line in BLOCKLIST_PATH.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # accept "0.0.0.0 domain", "domain", or hostfile style
            parts = line.split()
            dom = parts[-1].lower().rstrip(".")
            domains.add(dom)
    return domains


def is_blocked(qname, blocklist):
    q = qname.lower().rstrip(".")
    for d in blocklist:
        if q == d or q.endswith("." + d):
            return True
    return False


def parse_qname(data):
    """Extract the queried name from a DNS packet (question section)."""
    idx = 12
    labels = []
    while True:
        length = data[idx]
        if length == 0:
            idx += 1
            break
        labels.append(data[idx + 1: idx + 1 + length].decode("latin1"))
        idx += 1 + length
    return ".".join(labels), idx  # idx now points just past QNAME


def nxdomain_response(query):
    """Build an NXDOMAIN reply echoing the question."""
    tid = query[:2]
    flags = struct.pack(">H", 0x8183)  # QR=1, RA=1, RCODE=3 (NXDOMAIN)
    counts = struct.pack(">HHHH", 1, 0, 0, 0)  # 1 question, 0 answers
    # question section is everything from offset 12 to end of qname+qtype+qclass
    qname, after = parse_qname(query)
    question = query[12: after + 4]
    return tid + flags + counts + question


def main():
    blocklist = load_blocklist()
    print(f"sinkhole: :{PORT}  upstream={UPSTREAM[0]}  blocked={len(blocklist)} domains")
    print(f"log -> {LOG_PATH}")

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind(("0.0.0.0", PORT))
    except PermissionError:
        print(f"Port {PORT} requires sudo. Try: sudo python3 sinkhole.py  (or PORT=5353 for testing)")
        return

    logf = LOG_PATH.open("a")
    seen = set()

    while True:
        try:
            data, client = sock.recvfrom(4096)
            qname, _ = parse_qname(data)
            blocked = is_blocked(qname, blocklist)

            if qname not in seen:
                seen.add(qname)
                flag = "🚫 BLOCK" if blocked else ("⚠︎ ad?  " if any(h in qname.lower() for h in AD_HINTS) else "       ")
                stamp = time.strftime("%H:%M:%S")
                line = f"{stamp} {flag} {qname}"
                print(line)
                logf.write(line + "\n")
                logf.flush()

            if blocked:
                sock.sendto(nxdomain_response(data), client)
            else:
                up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                up.settimeout(4)
                up.sendto(data, UPSTREAM)
                try:
                    resp, _ = up.recvfrom(4096)
                    sock.sendto(resp, client)
                except socket.timeout:
                    pass
                finally:
                    up.close()
        except KeyboardInterrupt:
            print("\nbye")
            break
        except Exception as e:
            print("err:", e)


if __name__ == "__main__":
    main()
