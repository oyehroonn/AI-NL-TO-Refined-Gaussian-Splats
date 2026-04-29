"""Session orchestration: IDs, run-dir layout, LAN IP, port allocation.

Run-dir naming for AR captures is intentionally short and human-friendly:
    ar_runs/run<N>__<slug>/
where <N> is the next free sequential index in ar_runs/, and <slug> is a
sanitized version of the user-supplied video name. Example:
    ar_runs/run3__kitchen_counter/

This is different from the upload pipeline which uses ISO timestamp run IDs.
"""

from __future__ import annotations

import re
import secrets
import socket
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def default_ar_runs_root() -> Path:
    return _repo_root() / "ar_runs"


_SAFE = re.compile(r"[^A-Za-z0-9_.-]+")


def slugify(name: str, max_len: int = 40) -> str:
    s = _SAFE.sub("_", (name or "").strip())
    s = s.strip("._")
    if not s:
        s = "capture"
    return s[:max_len].rstrip("._") or "capture"


def _next_run_index(ar_runs_root: Path) -> int:
    if not ar_runs_root.is_dir():
        return 1
    used: set[int] = set()
    pat = re.compile(r"^run(\d+)(?:__.*)?$")
    for child in ar_runs_root.iterdir():
        m = pat.match(child.name)
        if m:
            try:
                used.add(int(m.group(1)))
            except ValueError:
                pass
    n = 1
    while n in used:
        n += 1
    return n


def allocate_run_dir(
    video_name: str,
    *,
    ar_runs_root: Path | None = None,
) -> tuple[Path, str]:
    """Create ar_runs/run<N>__<slug>/ and return (run_dir, run_id)."""
    root = (ar_runs_root or default_ar_runs_root()).resolve()
    root.mkdir(parents=True, exist_ok=True)
    n = _next_run_index(root)
    slug = slugify(video_name)
    run_id = f"run{n}__{slug}"
    run_dir = root / run_id
    if run_dir.exists():
        # extremely unlikely race; pick a uuid suffix and keep going
        run_id = f"run{n}__{slug}_{secrets.token_hex(2)}"
        run_dir = root / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    (run_dir / "capture").mkdir()
    (run_dir / "capture" / "frames").mkdir()
    (run_dir / "capture" / "depth").mkdir()
    (run_dir / "capture" / "depth_smoothed").mkdir()
    (run_dir / "metadata").mkdir()
    (run_dir / "logs").mkdir()
    return run_dir, run_id


def detect_lan_ip() -> str:
    """Best-effort LAN IPv4 detection.

    Trick: open a UDP socket to a public address; the OS picks the outbound
    interface and we read its local IP. No packet is sent. Falls back to
    hostname lookup, then 127.0.0.1.
    """
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
        finally:
            s.close()
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        pass
    try:
        host_ip = socket.gethostbyname(socket.gethostname())
        if host_ip and not host_ip.startswith("127."):
            return host_ip
    except OSError:
        pass
    return "127.0.0.1"


def find_free_port(preferred_range: tuple[int, int] = (8765, 8800)) -> int:
    """Try preferred range first, fall back to OS-assigned ephemeral port."""
    lo, hi = preferred_range
    for port in range(lo, hi + 1):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("0.0.0.0", port))
                return port
            except OSError:
                continue
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("0.0.0.0", 0))
        return s.getsockname()[1]


@dataclass
class CaptureSession:
    """In-memory state of one capture session."""

    session_id: str
    run_id: str
    run_dir: Path
    video_name: str
    scene_type: str
    host_ip: str
    port: int
    started_at: float
    expires_at: float
    protocol_version: int = 1
    received: bool = False
    extra: dict[str, Any] = field(default_factory=dict)

    @property
    def http_url(self) -> str:
        return f"http://{self.host_ip}:{self.port}"

    @property
    def deep_link(self) -> str:
        return (
            f"claudesplat://join?session={self.session_id}"
            f"&host={self.host_ip}:{self.port}&v={self.protocol_version}"
        )

    @property
    def join_url(self) -> str:
        return (
            f"http://{self.host_ip}:{self.port}/join"
            f"?session={self.session_id}&v={self.protocol_version}"
        )

    def to_descriptor(self) -> dict[str, Any]:
        return {
            "session_id": self.session_id,
            "run_id": self.run_id,
            "video_name": self.video_name,
            "scene_type_default": self.scene_type,
            "protocol_version": self.protocol_version,
            "expires_at_unix": int(self.expires_at),
        }

    def to_session_metadata(self) -> dict[str, Any]:
        return {
            **self.to_descriptor(),
            "started_at_unix": self.started_at,
            "host_ip": self.host_ip,
            "port": self.port,
            "http_url": self.http_url,
            "deep_link": self.deep_link,
            "join_url": self.join_url,
            "run_dir": str(self.run_dir),
        }


def new_session(
    *,
    video_name: str,
    scene_type: str = "room",
    timeout_seconds: int = 900,
    ar_runs_root: Path | None = None,
    preferred_port_range: tuple[int, int] = (8765, 8800),
) -> CaptureSession:
    run_dir, run_id = allocate_run_dir(video_name, ar_runs_root=ar_runs_root)
    sid = uuid.uuid4().hex[:8]
    now = time.time()
    return CaptureSession(
        session_id=sid,
        run_id=run_id,
        run_dir=run_dir,
        video_name=video_name,
        scene_type=scene_type,
        host_ip=detect_lan_ip(),
        port=find_free_port(preferred_port_range),
        started_at=now,
        expires_at=now + timeout_seconds,
    )
