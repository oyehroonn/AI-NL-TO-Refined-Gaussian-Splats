"""Fake-phone CLI uploader.

Lets us test AR-Layer 0 end-to-end without an iOS app. Given a folder of
images and a running session URL, it fabricates a manifest matching the
contract in CAPTURE_PROTOCOL.md and POSTs it as a multipart upload.

Pose values are PLAUSIBLE STUBS only — small forward-translating poses with
identity rotation. They are not meant to drive a real splat. Their job is
to pass schema validation so we can confirm the transport works.

Usage:
    python -m ar_capture_to_splat.session_layer.fake_phone \\
        --session-url http://192.168.1.5:8765 \\
        --frames-dir runs/<some-run>/images
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Iterable


def _read_session(session_url: str) -> dict:
    with urllib.request.urlopen(session_url.rstrip("/") + "/session", timeout=10) as r:
        return json.loads(r.read().decode("utf-8"))


def _identity_intrinsics(width: int, height: int) -> list[list[float]]:
    fx = fy = float(max(width, height))
    cx, cy = width / 2.0, height / 2.0
    return [[fx, 0.0, cx], [0.0, fy, cy], [0.0, 0.0, 1.0]]


def _stub_pose(idx: int) -> list[list[float]]:
    # identity rotation, small forward translation per frame so consecutive
    # frames are not literally identical (some downstream layers will choke
    # on duplicate poses).
    tz = 0.05 * idx
    return [
        [1.0, 0.0, 0.0, 0.0],
        [0.0, 1.0, 0.0, 0.0],
        [0.0, 0.0, 1.0, tz],
        [0.0, 0.0, 0.0, 1.0],
    ]


def _build_manifest(
    *,
    session: dict,
    frame_paths: list[Path],
    image_size: tuple[int, int],
    started_at: float,
    ended_at: float,
) -> dict:
    width, height = image_size
    intr = _identity_intrinsics(width, height)
    frames = []
    for i, p in enumerate(frame_paths):
        frames.append(
            {
                "frame_id": i,
                "timestamp": started_at + i * (1.0 / 30.0),
                "image_path": f"frames/{p.name}",
                "camera_transform_world": _stub_pose(i),
                "camera_intrinsics": intr,
                "image_width": width,
                "image_height": height,
                "tracking_state": "normal",
                "tracking_reason": None,
                "world_mapping_status": "extending",
                "raw_feature_points_count": 1500 + i,
                "has_scene_depth": False,
                "pose_quality_score": 0.9,
                "blur_score": 150.0,
                "coverage_score": 0.6,
                "accepted_for_training": True,
            }
        )
    return {
        "schema_version": 1,
        "session_id": session["session_id"],
        "run_id": session["run_id"],
        "video_name": session.get("video_name", "fake_phone"),
        "scene_type": session.get("scene_type_default", "room"),
        "started_at_unix": started_at,
        "ended_at_unix": ended_at,
        "device": {
            "model": "fake_phone",
            "os": "fake_os",
            "lidar_supported": False,
            "scene_reconstruction_supported": False,
            "ar_world_tracking_configuration": {
                "video_format": {"width": width, "height": height, "fps": 30},
                "frame_semantics": [],
                "plane_detection": [],
                "scene_reconstruction": "none",
            },
        },
        "summary": {
            "frames_captured": len(frame_paths),
            "frames_kept": len(frame_paths),
            "duration_seconds": max(0.0, ended_at - started_at),
            "tracking_state_breakdown": {"normal": len(frame_paths), "limited": 0, "notAvailable": 0},
            "world_mapping_status_breakdown": {"extending": len(frame_paths)},
            "coverage_summary": {"covered_fraction": 0.6, "weak_regions": []},
            "preview_run": False,
            "enhance_run": False,
        },
        "frames": frames,
    }


def _peek_image_size(path: Path) -> tuple[int, int]:
    """Best-effort size lookup using stdlib only.

    Falls back to (1920, 1080) if the format isn't recognised. Layer 0 only
    needs SOMETHING valid in the manifest; downstream layers can re-read
    actual dimensions from the JPEGs.
    """
    try:
        import imghdr  # noqa: F401  (kept for clarity; not strictly needed)
        # Minimal JPEG SOF parser:
        data = path.read_bytes()
        i = 0
        while i < len(data) - 9:
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            i += 2
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                # SOFn segment
                # i now points past marker; next 2 bytes = segment length, then 1 byte precision,
                # then 2 bytes height, 2 bytes width.
                if i + 7 >= len(data):
                    break
                height = (data[i + 3] << 8) | data[i + 4]
                width = (data[i + 5] << 8) | data[i + 6]
                if height > 0 and width > 0:
                    return width, height
                break
            elif marker == 0xD9 or marker == 0xD8:
                break
            else:
                if i + 1 >= len(data):
                    break
                seg_len = (data[i] << 8) | data[i + 1]
                i += seg_len
    except Exception:  # noqa: BLE001
        pass
    return 1920, 1080


def _multipart_body(
    *,
    boundary: str,
    session_id: str,
    manifest_bytes: bytes,
    frame_paths: Iterable[Path],
) -> bytes:
    parts: list[bytes] = []
    bnd = boundary.encode("ascii")

    def add(headers: list[str], payload: bytes) -> None:
        parts.append(b"--" + bnd + b"\r\n")
        for h in headers:
            parts.append(h.encode("utf-8") + b"\r\n")
        parts.append(b"\r\n")
        parts.append(payload)
        parts.append(b"\r\n")

    add(
        ['Content-Disposition: form-data; name="session_id"'],
        session_id.encode("utf-8"),
    )
    add(
        [
            'Content-Disposition: form-data; name="manifest"; filename="manifest.json"',
            "Content-Type: application/json",
        ],
        manifest_bytes,
    )
    for p in frame_paths:
        add(
            [
                f'Content-Disposition: form-data; name="frames"; filename="frames/{p.name}"',
                "Content-Type: image/jpeg",
            ],
            p.read_bytes(),
        )
    parts.append(b"--" + bnd + b"--\r\n")
    return b"".join(parts)


def _gather_frames(frames_dir: Path, *, limit: int | None) -> list[Path]:
    exts = {".jpg", ".jpeg"}
    found = sorted([p for p in frames_dir.iterdir() if p.is_file() and p.suffix.lower() in exts])
    if not found:
        raise FileNotFoundError(f"No .jpg files found in {frames_dir}")
    if limit is not None and limit > 0:
        found = found[:limit]
    return found


def main() -> None:
    parser = argparse.ArgumentParser(description="Fake phone uploader for AR-Layer 0 testing.")
    parser.add_argument("--session-url", required=True, help="e.g. http://192.168.1.5:8765")
    parser.add_argument("--frames-dir", required=True, type=Path)
    parser.add_argument("--limit", type=int, default=20, help="Max frames to upload (default 20).")
    parser.add_argument("--scene-type", default=None)
    args = parser.parse_args()

    session_url = args.session_url.rstrip("/")
    print(f"Querying session at {session_url}/session ...")
    session = _read_session(session_url)
    print(f"Session id: {session['session_id']}  Run id: {session['run_id']}")

    frame_paths = _gather_frames(args.frames_dir, limit=args.limit)
    print(f"Uploading {len(frame_paths)} frames from {args.frames_dir}")

    width, height = _peek_image_size(frame_paths[0])
    started = time.time()
    manifest = _build_manifest(
        session=session,
        frame_paths=frame_paths,
        image_size=(width, height),
        started_at=started,
        ended_at=started + len(frame_paths) / 30.0,
    )
    if args.scene_type:
        manifest["scene_type"] = args.scene_type
    manifest_bytes = json.dumps(manifest).encode("utf-8")

    boundary = "fakephone-" + uuid.uuid4().hex
    body = _multipart_body(
        boundary=boundary,
        session_id=session["session_id"],
        manifest_bytes=manifest_bytes,
        frame_paths=frame_paths,
    )

    req = urllib.request.Request(
        url=session_url + "/upload",
        data=body,
        method="POST",
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            print(f"HTTP {resp.status}")
            print(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}", file=sys.stderr)
        try:
            print(e.read().decode("utf-8"), file=sys.stderr)
        except Exception:  # noqa: BLE001
            pass
        sys.exit(1)


if __name__ == "__main__":
    main()
