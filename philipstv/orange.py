"""
Orange Polska TV decoder (Sagemcom, SoftAtHome middleware) — local HTTP remote API.

Same API as Orange France's Livebox decoders (SSDP service
urn:schemas-orange-com:service:X_OrangeSTBRemoteControl:1), no auth:

  GET http://<box>:8080/remoteControl/cmd?operation=10                  status
  GET http://<box>:8080/remoteControl/cmd?operation=01&key=<code>&mode=0  key press

Status: activeStandbyState "0" = on, "1" = standby; osdContext HOMEPAGE / LIVE / …;
playedMediaId = current channel id (e.g. 14135 = TVP1). The box reports
wolSupport "0": once it drops off the network only its own remote can wake it.
"""

from __future__ import annotations

import requests

KEYS = {
    "power": 116, "ok": 352, "back": 158, "menu": 139,
    "up": 103, "down": 108, "left": 105, "right": 106,
    "channel_up": 402, "channel_down": 403,
    "volume_up": 115, "volume_down": 114, "mute": 113,
    "play_pause": 164, "rewind": 168, "forward": 159, "record": 167, "vod": 393,
    **{str(n): 512 + n for n in range(10)},  # digits: tune by channel number
}


class OrangeBox:
    def __init__(self, host: str = "192.168.0.244"):
        self.base = f"http://{host}:8080/remoteControl/cmd"

    def _call(self, **params) -> dict:
        r = requests.get(self.base, params=params, timeout=4).json()["result"]
        if r.get("responseCode") != "0":
            raise RuntimeError(r.get("message"))
        return r.get("data", {})

    def status(self) -> dict:
        return self._call(operation="10")

    def press(self, key: str | int) -> None:
        code = KEYS[key] if isinstance(key, str) else key
        self._call(operation="01", key=code, mode="0")

    def tune(self, number: int) -> None:
        """Go to a channel by its number (digit keys)."""
        for d in str(number):
            self.press(d)
