"""
Philips Titan OS (JointSpace v6) client.

Handles secure PIN pairing (``digest_auth_pairing``) and sending commands to
Philips TVs that expose the JointSpace v6 API over ``https://<ip>:1926/6/...``.

Pairing flow:
  1. POST /6/pair/request  -> TV shows a PIN on screen, returns auth_key + timestamp
  2. signature = base64( HMAC-SHA1(shared_key, timestamp + pin) )   (raw digest bytes)
  3. POST /6/pair/grant    (HTTP Digest auth using device_id + auth_key)
  4. store (device_id, auth_key); use Digest auth for every later request

The shared key + signature scheme below match ha-philipsjs (the implementation
Home Assistant uses), which is the one that works on current Titan OS firmware.
The older pylips key does NOT work on these TVs.

Credentials are stored in ~/.philips-tv-remote/credentials.json (mode 600).
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
from pathlib import Path
from typing import Optional

import requests
from requests.auth import HTTPDigestAuth
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# b64-decoded before use as the HMAC key. Public, well-known JointSpace v6 key.
AUTH_SHARED_KEY = base64.b64decode(
    "ZmVay1EQVFOaZhwQ4Kv81ypLAZNczV9sG4KkseXWn1NEk6cXmPKO/MCa9sryslvLCFMnNe4Z4CPXzToowvhHvA=="
)

CONFIG_DIR = Path.home() / ".philips-tv-remote"
CRED_FILE = CONFIG_DIR / "credentials.json"
PAIR_STATE = CONFIG_DIR / "pair_state.json"

APP_NAME = "PhilipsTVMenubar"
DEVICE_NAME = "macbook"


def _device_spec(device_id: str) -> dict:
    return {
        "device_name": DEVICE_NAME,
        "device_os": "Android",
        "type": "native",
        "id": device_id,
        "app_id": "app.id",
        "app_name": APP_NAME,
    }


def _sign(timestamp, pin) -> str:
    """HMAC-SHA1 over timestamp then pin; base64 of the RAW digest bytes."""
    h = hmac.new(AUTH_SHARED_KEY, digestmod=hashlib.sha1)
    h.update(str(timestamp).encode())
    h.update(str(pin).encode())
    return base64.b64encode(h.digest()).decode()


class PhilipsError(Exception):
    pass


class PhilipsTV:
    def __init__(self, host: str, device_id: Optional[str] = None, auth_key: Optional[str] = None):
        self.host = host
        self.base = f"https://{host}:1926/6"
        self.device_id = device_id
        self.auth_key = auth_key

    # ------------------------------------------------------------------ creds
    @classmethod
    def load(cls) -> Optional["PhilipsTV"]:
        if CRED_FILE.exists():
            data = json.loads(CRED_FILE.read_text())
            return cls(data["host"], data["device_id"], data["auth_key"])
        return None

    def save(self) -> None:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        CRED_FILE.write_text(json.dumps({
            "host": self.host,
            "device_id": self.device_id,
            "auth_key": self.auth_key,
        }, indent=2))
        CRED_FILE.chmod(0o600)

    @property
    def paired(self) -> bool:
        return bool(self.device_id and self.auth_key)

    @property
    def _auth(self) -> Optional[HTTPDigestAuth]:
        if self.paired:
            return HTTPDigestAuth(self.device_id, self.auth_key)
        return None

    # --------------------------------------------------------------- pairing
    def pair_request(self):
        """Step 1: ask the TV to display a PIN. Returns (device_id, timestamp)."""
        device_id = secrets.token_hex(16)
        access = {"scope": ["read", "write", "control"]}
        try:
            featuring = self.system().get("featuring")
            if featuring:
                access["featuring"] = featuring
        except Exception:
            pass
        payload = {"access": access, "device": _device_spec(device_id)}
        data = self._raw_post("pair/request", payload, auth=None)
        if data.get("error_id") not in (None, "SUCCESS"):
            raise PhilipsError(f"pair/request failed: {data}")
        self.device_id = device_id
        self.auth_key = data["auth_key"]  # temporary key, used only to sign the grant
        # persist pending state so pairing can span two CLI invocations
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        PAIR_STATE.write_text(json.dumps({
            "host": self.host, "device_id": device_id,
            "auth_key": self.auth_key, "timestamp": data["timestamp"],
        }))
        return device_id, data["timestamp"]

    def pair_grant(self, pin, timestamp) -> bool:
        """Step 2: send the PIN + signature to finish pairing."""
        payload = {
            "auth": {
                "auth_appId": "1",
                "auth_timestamp": timestamp,
                "auth_signature": _sign(timestamp, pin),
                "pin": str(pin),
            },
            "device": _device_spec(self.device_id),
        }
        data = self._raw_post("pair/grant", payload,
                              auth=HTTPDigestAuth(self.device_id, self.auth_key))
        if data.get("error_id") not in (None, "SUCCESS"):
            raise PhilipsError(f"pair/grant failed: {data}")
        self.save()
        PAIR_STATE.unlink(missing_ok=True)
        return True

    @classmethod
    def resume_pairing(cls):
        """Load pending pairing state saved by a previous pair_request()."""
        if not PAIR_STATE.exists():
            raise PhilipsError("No pending pairing. Run pair_request() first.")
        st = json.loads(PAIR_STATE.read_text())
        tv = cls(st["host"], st["device_id"], st["auth_key"])
        return tv, st["timestamp"]

    # ------------------------------------------------------------ transport
    def _raw_post(self, path, body, auth):
        r = requests.post(f"{self.base}/{path}", json=body, auth=auth, verify=False, timeout=8)
        r.raise_for_status()
        return self._decode(r)

    @staticmethod
    def _decode(r):
        txt = (r.text or "").strip()
        if not txt:
            return {"ok": True}
        try:
            return r.json()
        except ValueError:
            return {"ok": True, "raw": txt}

    def _get(self, path):
        r = requests.get(f"{self.base}/{path}", auth=self._auth, verify=False, timeout=6)
        r.raise_for_status()
        return self._decode(r)

    def _post(self, path, body):
        r = requests.post(f"{self.base}/{path}", json=body, auth=self._auth, verify=False, timeout=6)
        r.raise_for_status()
        return self._decode(r)

    # -------------------------------------------------------------- commands
    def system(self) -> dict:
        """/6/system is readable without pairing."""
        r = requests.get(f"{self.base}/system", verify=False, timeout=6)
        r.raise_for_status()
        return r.json()

    def send_key(self, key: str):
        """Send a remote key. See KEYS for the common names."""
        return self._post("input/key", {"key": key})

    # -- power --
    def powerstate(self) -> dict:
        return self._get("powerstate")

    def is_on(self) -> bool:
        try:
            return self.powerstate().get("powerstate") == "On"
        except Exception:
            return False

    def set_power(self, on: bool = True):
        return self._post("powerstate", {"powerstate": "On" if on else "Standby"})

    def toggle_power(self):
        return self.send_key("Standby")

    # -- volume (routed to HDMI-ARC soundbar via CEC; use keys, not set_volume) --
    def volume_up(self):
        return self.send_key("VolumeUp")

    def volume_down(self):
        return self.send_key("VolumeDown")

    def mute(self):
        return self.send_key("Mute")

    def get_volume(self) -> dict:
        """Internal TV-speaker volume only. Unreliable when audio is on a soundbar."""
        return self._get("audio/volume")

    # -- activities --
    def current_activity(self) -> dict:
        return self._get("activities/current")

    # -- ambilight --
    def ambilight_power(self, on: bool = True):
        return self._post("ambilight/power", {"power": "On" if on else "Off"})

    def ambilight_supported_styles(self) -> dict:
        return self._get("ambilight/supportedstyles")

    def ambilight_config(self) -> dict:
        return self._get("ambilight/currentconfiguration")

    def ambilight_set(self, style_name: str, menu_setting: Optional[str] = None,
                      algorithm: Optional[str] = None):
        """Set an Ambilight style, e.g.:
            ambilight_set("FOLLOW_VIDEO", menu_setting="NATURAL")
            ambilight_set("FOLLOW_AUDIO", algorithm="VU_METER")
            ambilight_set("OFF")
        """
        cfg: dict = {"styleName": style_name, "isExpert": False}
        if menu_setting:
            cfg["menuSetting"] = menu_setting
        if algorithm:
            cfg["algorithm"] = algorithm
        return self._post("ambilight/currentconfiguration", cfg)

    def ambilight_off(self):
        return self.ambilight_set("OFF")

    def ambilight_follow_video(self, menu_setting: str = "NATURAL"):
        return self.ambilight_set("FOLLOW_VIDEO", menu_setting=menu_setting)

    def ambilight_follow_audio(self, algorithm: str = "ENERGY_ADAPTIVE_BRIGHTNESS"):
        return self.ambilight_set("FOLLOW_AUDIO", algorithm=algorithm)


# Common JointSpace remote key names.
KEYS = [
    "Standby", "Back", "Home", "Options", "Info", "Source",
    "CursorUp", "CursorDown", "CursorLeft", "CursorRight", "Confirm",
    "VolumeUp", "VolumeDown", "Mute",
    "ChannelStepUp", "ChannelStepDown",
    "PlayPause", "Play", "Pause", "Stop", "FastForward", "Rewind", "Next", "Previous",
    "Digit0", "Digit1", "Digit2", "Digit3", "Digit4",
    "Digit5", "Digit6", "Digit7", "Digit8", "Digit9",
    "RedColour", "GreenColour", "YellowColour", "BlueColour",
    "Subtitle", "Teletext", "Viewmode", "AmbilightOnOff", "WatchTV",
]
