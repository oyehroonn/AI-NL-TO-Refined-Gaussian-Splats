"""QR rendering for AR-Layer 0 handoff.

Two artifacts per session:
  - terminal ASCII QR (printed inline so the user can scan from the laptop screen)
  - PNG saved under ar_runs/<run_id>/capture/qr_*.png and auto-opened on macOS

Encodes both the deep-link (custom URL scheme for the future iOS app) and
the http fallback (so any QR scanner / mobile Safari works during dev).
"""

from __future__ import annotations

import io
import shutil
import subprocess
import sys
from pathlib import Path

import qrcode
from qrcode.constants import ERROR_CORRECT_M


def _ascii_qr(payload: str) -> str:
    qr = qrcode.QRCode(
        version=None,
        error_correction=ERROR_CORRECT_M,
        box_size=1,
        border=2,
    )
    qr.add_data(payload)
    qr.make(fit=True)
    buf = io.StringIO()
    qr.print_ascii(out=buf, invert=True)
    return buf.getvalue()


def _save_png(payload: str, out_path: Path) -> Path:
    img = qrcode.make(payload, error_correction=ERROR_CORRECT_M, box_size=10, border=4)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path)
    return out_path


def _try_open(path: Path) -> bool:
    if sys.platform == "darwin" and shutil.which("open"):
        try:
            subprocess.Popen(
                ["open", str(path)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return True
        except OSError:
            return False
    return False


def display_session_qrs(
    *,
    deep_link: str,
    http_url: str,
    out_dir: Path,
    open_png: bool = True,
) -> dict[str, Path]:
    """Print ASCII QRs to stdout and save PNGs.

    Returns paths to the saved PNGs so the orchestrator can log them.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    deep_png = _save_png(deep_link, out_dir / "qr_deep_link.png")
    http_png = _save_png(http_url, out_dir / "qr_http_fallback.png")

    print()
    print("=" * 72)
    print(" SCAN ON YOUR iPHONE")
    print("=" * 72)
    print()
    print("Primary (opens ClaudeSplat app — once installed):")
    print(f"  {deep_link}")
    print()
    print(_ascii_qr(deep_link))
    print()
    print("Fallback (opens in Safari — works for fake_phone testing):")
    print(f"  {http_url}")
    print()
    print(_ascii_qr(http_url))
    print(f"PNGs saved to: {out_dir}")
    print("=" * 72)
    print()

    if open_png:
        # Open the http fallback PNG — easier to scan from the laptop screen
        # without an installed app.
        _try_open(http_png)

    return {"deep_link_png": deep_png, "http_png": http_png}
