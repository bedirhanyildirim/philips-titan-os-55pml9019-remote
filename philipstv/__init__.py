"""philipstv — control a Philips Titan OS TV over the local network (JointSpace v6)."""

from .client import PhilipsTV, CONFIG_DIR, CRED_FILE

__all__ = ["PhilipsTV", "CONFIG_DIR", "CRED_FILE"]
__version__ = "0.1.0"
