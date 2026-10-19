#!/usr/bin/env python3
"""
Pair with the TV's Titan OS control channel (MQTT :8883) — needed to launch any app
(Disney+, HBO Max, …), send keys over MQTT and select sources.

    python3 titan_pair.py 192.168.0.45
    python3 titan_pair.py --apps                 # list installed apps
    python3 titan_pair.py --launch disney        # launch by app code
"""

import sys

from philipstv.titan import Titan


def main():
    args = sys.argv[1:]
    if args and args[0] == "--apps":
        t = Titan.load().connect()
        for a in t.installed_apps():
            print(f"{a['code']:18s} {a['name']:22s} {a['url']}")
        t.close()
    elif args and args[0] == "--launch":
        t = Titan.load().connect()
        app = next(a for a in t.installed_apps() if a["code"] == args[1])
        print(t.launch(app["code"], app["url"]))
        t.close()
    elif args:
        t = Titan(args[0]).connect()
        t.pair_start()
        pin = input("PIN shown on the TV: ").strip()
        t.pair_finish(pin)
        t.close()
        print("Paired. Credentials saved to ~/.philips-tv-remote/titan_mqtt.json")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
