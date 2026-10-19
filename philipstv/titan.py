"""
Titan OS local control channel: MQTT v5 over TLS on port 8883.

This is what the official "Titan OS Mobile" app (tv.titanos.eos.mobile) uses.
Unlike JointSpace — where /6/applications and /6/sources are 403 on Titan OS —
it can launch ANY installed app (Disney+, HBO Max, …) and send remote keys.

  * TLS: the server cert chains to the "Titanos Root CA" bundled with the mobile app
    (titan_ca.crt next to this file). No client cert; hostname isn't checked.
  * Pairing: anonymous connect → request `pairing/start {"type":"mobile"}` → TV shows
    a 4-digit PIN → `pairing/finish {"username", "challenge_result"}` with
    challenge_result = hex(HMAC-SHA256(key=PIN, msg=challenge)) → returns a password.
  * Requests: subscribe `<topic>/<uuid>`, publish to `<topic>` with MQTT5
    ResponseTopic + CorrelationData = that topic, wait for the reply.

Useful topics (advertised in the retained `info` message):
  deeplink  {"app_code": "<code>", "url": "<url>"}   launch an app (codes/urls from
            the TV's own list: proxy → /v1/me/user_apps)
  rc        {"key_code": N}                         Linux input keycode (see KEYCODES)
  keyboard  {"opcode": 0, "text": "a"}               type one character
  proxy     {"endpoint": "/v1/me/...", ...}          TV's authenticated Titan cloud API

Credentials are stored in ~/.philips-tv-remote/titan_mqtt.json (mode 600).
"""

from __future__ import annotations

import hashlib
import hmac
import json
import ssl
import threading
import time
import uuid
from pathlib import Path
from typing import Optional

import paho.mqtt.client as mqtt
from paho.mqtt.packettypes import PacketTypes
from paho.mqtt.properties import Properties

CA_FILE = Path(__file__).with_name("titan_ca.crt")
CRED_FILE = Path.home() / ".philips-tv-remote" / "titan_mqtt.json"

# Linux input keycodes for the `rc` topic (from the Titan OS Mobile app; Next/Previous/
# FastForward/Rewind/Info/WatchTV are the standard input-event-codes.h values).
KEYCODES = {
    "Confirm": 352, "Back": 158, "Home": 102,
    "CursorUp": 103, "CursorDown": 108, "CursorLeft": 105, "CursorRight": 106,
    "VolumeUp": 115, "VolumeDown": 114, "Mute": 113, "Standby": 116,
    "Play": 207, "Pause": 119, "PlayPause": 164, "Stop": 128,
    "Options": 357, "QuickMenu": 139, "Source": 394, "TvGuide": 365,
    "ChannelStepUp": 402, "ChannelStepDown": 403,
    "RedColour": 398, "GreenColour": 399, "YellowColour": 400, "BlueColour": 401,
    "WatchTV": 377,  # KEY_TV: jumps to the last-used tuner
    "Next": 163, "Previous": 165, "FastForward": 208, "Rewind": 168, "Info": 358,
}


class TitanError(Exception):
    pass


class Titan:
    def __init__(self, host: str, username: Optional[str] = None, password: Optional[str] = None):
        self.host = host
        self.username = username
        self.password = password
        self._waiters: dict = {}
        self._connected = threading.Event()
        self._challenge: Optional[str] = None
        cid = "eos-" + (username or uuid.uuid4().hex)
        self.c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=cid, protocol=mqtt.MQTTv5)
        ctx = ssl.create_default_context(cafile=str(CA_FILE))
        ctx.check_hostname = False
        self.c.tls_set_context(ctx)
        if username:
            self.c.username_pw_set(username, password)
        self.c.on_connect = lambda c, u, f, rc, p: self._connected.set()
        self.c.on_message = self._on_message

    # ------------------------------------------------------------------ creds
    @classmethod
    def load(cls) -> Optional["Titan"]:
        if CRED_FILE.exists():
            d = json.loads(CRED_FILE.read_text())
            return cls(d["host"], d["username"], d["password"])
        return None

    def save(self) -> None:
        CRED_FILE.parent.mkdir(parents=True, exist_ok=True)
        CRED_FILE.write_text(json.dumps(
            {"host": self.host, "username": self.username, "password": self.password}, indent=2))
        CRED_FILE.chmod(0o600)

    # -------------------------------------------------------------- transport
    def connect(self) -> "Titan":
        self.c.connect(self.host, 8883, keepalive=30)
        self.c.loop_start()
        if not self._connected.wait(8):
            raise TitanError("connect timeout")
        return self

    def close(self) -> None:
        self.c.loop_stop()
        self.c.disconnect()

    def _on_message(self, c, u, m):
        w = self._waiters.get(m.topic)
        if w:
            w[1].append(m.payload.decode(errors="replace"))
            w[0].set()

    def request(self, topic: str, payload: Optional[dict], timeout: float = 6) -> dict:
        rt = f"{topic}/{uuid.uuid4()}"
        ev = threading.Event()
        self._waiters[rt] = (ev, [])
        self.c.subscribe(rt, qos=0)
        time.sleep(0.3)
        props = Properties(PacketTypes.PUBLISH)
        props.ResponseTopic = rt
        props.CorrelationData = rt.encode()
        data = b"" if payload is None else json.dumps(payload).encode()
        self.c.publish(topic, data, qos=0, properties=props)
        ev.wait(timeout)
        res = self._waiters.pop(rt)[1]
        if not res:
            raise TitanError(f"{topic}: no reply")
        return json.loads(res[0])

    def publish(self, topic: str, payload: dict) -> None:
        self.c.publish(topic, json.dumps(payload).encode(), qos=0)

    # ---------------------------------------------------------------- pairing
    def pair_start(self) -> None:
        """Step 1 (anonymous connection): the TV shows a 4-digit PIN."""
        r = self.request("pairing/start", {"type": "mobile"})
        if "data" not in r:
            raise TitanError(f"pairing/start failed: {r}")
        self._challenge = r["data"]["challenge"]

    def pair_finish(self, pin: str) -> None:
        """Step 2: answer the challenge with the PIN; saves credentials."""
        username = str(uuid.uuid4())
        result = hmac.new(pin.encode(), self._challenge.encode(), hashlib.sha256).hexdigest()
        r = self.request("pairing/finish", {"username": username, "challenge_result": result})
        if "data" not in r:
            raise TitanError(f"pairing/finish failed: {r}")
        self.username = r["data"].get("username", username)
        self.password = r["data"]["password"]
        self.save()

    # --------------------------------------------------------------- commands
    def launch(self, app_code: str, url: str) -> dict:
        return self.request("deeplink", {"app_code": app_code, "url": url})

    def key(self, name: str) -> None:
        self.publish("rc", {"key_code": KEYCODES[name]})

    def type_text(self, text: str) -> None:
        for ch in text:
            self.publish("keyboard", {"opcode": 0, "text": ch})

    def installed_apps(self) -> list:
        """The TV's home-screen apps: [{code, name, url, app_type, ...}, ...]."""
        r = self.request("proxy", {
            "endpoint": "/v1/me/user_apps", "method": "GET", "headers": {},
            "query_params": {"page": "1", "per_page": "50"}, "authenticated": True, "api": "gaea",
        })
        body = r["data"]["body"]
        body = json.loads(body) if isinstance(body, str) else body
        return [e["app"] for e in body.get("collection", [])]
