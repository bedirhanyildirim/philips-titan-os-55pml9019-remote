#!/usr/bin/env python3
"""
Interactive pairing for a Philips Titan OS TV.

Usage:
    python3 pair.py <tv-ip>

The TV must be ON. A PIN appears on the TV screen (~30s). Type it in.
"""

import sys

from philipstv import PhilipsTV
from philipstv.client import PhilipsError


def main():
    if len(sys.argv) != 2:
        print("Kullanım: python3 pair.py <tv-ip>")
        print("Örnek:    python3 pair.py 192.168.0.45")
        sys.exit(1)

    host = sys.argv[1]
    tv = PhilipsTV(host)

    try:
        info = tv.system()
        print(f"TV bulundu: {info.get('name')} ({info.get('country')}), "
              f"API v{info.get('api_version', {}).get('Major')}")
    except Exception as e:
        print(f"TV'ye ulaşılamadı ({host}:1926): {e}")
        sys.exit(1)

    print("\nEşleştirme isteği gönderiliyor — TV ekranına bak…")
    try:
        _, timestamp = tv.pair_request()
    except Exception as e:
        print(f"pair/request başarısız: {e}")
        sys.exit(1)

    print("TV ekranında bir PIN göründü (yaklaşık 30 saniye geçerli).")
    pin = input("PIN: ").strip()

    try:
        tv.pair_grant(pin, timestamp)
    except PhilipsError as e:
        print(f"\n❌ Eşleştirme başarısız: {e}")
        print("PIN süresi dolmuş olabilir — tekrar dene.")
        sys.exit(1)

    print("\n✅ Eşleştirme başarılı! Kimlik bilgileri ~/.philips-tv-remote/ içine kaydedildi.")
    try:
        print(f"   Güç durumu: {tv.powerstate().get('powerstate')}")
    except Exception:
        pass
    print("\nArtık menü çubuğu uygulamasını başlatabilirsin:  python3 run.py")


if __name__ == "__main__":
    main()
