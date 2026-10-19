"""
macOS menu bar app for controlling a Philips Titan OS TV.

Run with:  python3 run.py
Pair first with:  python3 pair.py <tv-ip>
"""

import threading

import rumps

from .client import PhilipsTV, PhilipsError


class PhilipsMenubar(rumps.App):
    def __init__(self):
        super().__init__("📺", quit_button=None)
        self.tv = PhilipsTV.load()
        self._build_menu()
        # refresh power state in the background every 30s
        rumps.Timer(self._refresh, 30).start()
        threading.Thread(target=self._refresh, daemon=True).start()

    # --------------------------------------------------------------- menu
    def _build_menu(self):
        self.status_item = rumps.MenuItem("Bağlanıyor…")

        remote = rumps.MenuItem("🎮 Kumanda")
        remote.update([
            rumps.MenuItem("▲ Yukarı", callback=self._key("CursorUp")),
            rumps.MenuItem("◀ Sol", callback=self._key("CursorLeft")),
            rumps.MenuItem("● OK", callback=self._key("Confirm")),
            rumps.MenuItem("▶ Sağ", callback=self._key("CursorRight")),
            rumps.MenuItem("▼ Aşağı", callback=self._key("CursorDown")),
            None,
            rumps.MenuItem("↩ Geri", callback=self._key("Back")),
            rumps.MenuItem("⚙ Seçenekler", callback=self._key("Options")),
            rumps.MenuItem("ℹ Info", callback=self._key("Info")),
        ])

        media = rumps.MenuItem("⏯ Medya")
        media.update([
            rumps.MenuItem("⏯ Oynat/Duraklat", callback=self._key("PlayPause")),
            rumps.MenuItem("⏹ Durdur", callback=self._key("Stop")),
            rumps.MenuItem("⏭ Sonraki", callback=self._key("Next")),
            rumps.MenuItem("⏮ Önceki", callback=self._key("Previous")),
            rumps.MenuItem("⏩ İleri sar", callback=self._key("FastForward")),
            rumps.MenuItem("⏪ Geri sar", callback=self._key("Rewind")),
        ])

        ambilight = rumps.MenuItem("🎨 Ambilight")
        ambilight.update([
            rumps.MenuItem("Ekranı takip et (Natural)",
                           callback=self._amb(lambda t: t.ambilight_follow_video("NATURAL"))),
            rumps.MenuItem("Ekranı takip et (Vivid)",
                           callback=self._amb(lambda t: t.ambilight_follow_video("VIVID"))),
            rumps.MenuItem("Sesi takip et (VU Meter)",
                           callback=self._amb(lambda t: t.ambilight_follow_audio("VU_METER"))),
            rumps.MenuItem("Sesi takip et (Parti)",
                           callback=self._amb(lambda t: t.ambilight_follow_audio("PARTY"))),
            None,
            rumps.MenuItem("Kapat", callback=self._amb(lambda t: t.ambilight_off())),
        ])

        self.menu = [
            self.status_item,
            None,
            rumps.MenuItem("⏻ Güç (Aç/Kapat)", callback=self._key("Standby")),
            None,
            rumps.MenuItem("🔊 Ses +", callback=self._key("VolumeUp")),
            rumps.MenuItem("🔉 Ses −", callback=self._key("VolumeDown")),
            rumps.MenuItem("🔇 Sessiz", callback=self._key("Mute")),
            None,
            rumps.MenuItem("🏠 Ana Ekran", callback=self._key("Home")),
            rumps.MenuItem("📡 Kaynak", callback=self._key("Source")),
            remote,
            media,
            ambilight,
            None,
            rumps.MenuItem("🔄 Durumu Yenile", callback=lambda _: self._refresh()),
            rumps.MenuItem("Çıkış", callback=rumps.quit_application),
        ]

    # ----------------------------------------------------------- callbacks
    def _key(self, key):
        def cb(_):
            self._do(lambda t: t.send_key(key), f"{key}")
        return cb

    def _amb(self, fn):
        def cb(_):
            self._do(fn, "Ambilight")
        return cb

    def _do(self, fn, label):
        if not self.tv or not self.tv.paired:
            rumps.notification("Philips TV", "Eşleştirilmemiş",
                               "Önce: python3 pair.py <tv-ip>")
            return
        try:
            fn(self.tv)
        except PhilipsError as e:
            rumps.notification("Philips TV", "Hata", str(e))
        except Exception as e:
            rumps.notification("Philips TV", f"{label} gönderilemedi", str(e))

    def _refresh(self, _=None):
        if not self.tv or not self.tv.paired:
            self.status_item.title = "⚠︎ Eşleştirilmemiş — pair.py çalıştır"
            self.title = "📺"
            return
        try:
            on = self.tv.is_on()
            model = ""
            try:
                model = self.tv.system().get("name", "")
            except Exception:
                pass
            self.status_item.title = f"{'🟢 Açık' if on else '⚪️ Kapalı'}  ·  {model}"
            self.title = "📺" if on else "📺"
        except Exception:
            self.status_item.title = "🔴 Bağlanılamadı"


def main():
    PhilipsMenubar().run()


if __name__ == "__main__":
    main()
