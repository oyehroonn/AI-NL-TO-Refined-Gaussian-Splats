"""Local HTTP server for AR-Layer 0 capture intake.

stdlib http.server on a background thread. No new deps. Routes:
  GET  /healthz          → "ok"
  GET  /session          → session descriptor JSON
  GET  /tutorial-config  → stub tip set keyed by ?scene_type=
  GET  /join             → minimal HTML landing page (Safari fallback)
  POST /upload           → multipart capture-package upload (the real work)

After a successful upload the server signals capture_complete on the
attached `threading.Event` and stops accepting further uploads.
"""

from __future__ import annotations

import cgi
import json
import logging
import os
import re
import shutil
import threading
import time
import urllib.parse
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from .scene_types import SCENE_TYPES, scene_tip_set
from .session import CaptureSession


log = logging.getLogger("ar_layer0.server")


# Hard upload cap — protects the laptop from a runaway iPhone or fake_phone.
DEFAULT_MAX_UPLOAD_BYTES = 4 * 1024 * 1024 * 1024  # 4 GiB

# Per-frame parts the manifest may reference. Mapping: form field name → folder.
_FRAME_PART_DIRS = {
    "frames": "frames",
    "depth": "depth",
    "depth_smoothed": "depth_smoothed",
}


@dataclass
class UploadResult:
    ok: bool
    frames_received: int = 0
    depth_received: int = 0
    smoothed_depth_received: int = 0
    tracking_state_breakdown: dict[str, int] | None = None
    error: str | None = None
    detail: Any | None = None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


_SAFE_REL = re.compile(r"^[A-Za-z0-9._/-]+$")


def _safe_relpath(rel: str) -> str | None:
    """Reject any path that escapes the run-dir (path-traversal guard)."""
    if not rel or rel.startswith("/") or ".." in rel.split("/"):
        return None
    if not _SAFE_REL.match(rel):
        return None
    return rel


def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


def _text_response(
    handler: BaseHTTPRequestHandler,
    status: int,
    text: str,
    *,
    content_type: str = "text/plain; charset=utf-8",
) -> None:
    body = text.encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Cache-Control", "no-store")
    handler.end_headers()
    handler.wfile.write(body)


# ---------------------------------------------------------------------------
# Manifest validation
# ---------------------------------------------------------------------------


_REQUIRED_FRAME_FIELDS = (
    "frame_id",
    "timestamp",
    "image_path",
    "camera_transform_world",
    "camera_intrinsics",
    "image_width",
    "image_height",
    "tracking_state",
    "accepted_for_training",
)

_REQUIRED_SESSION_FIELDS = (
    "schema_version",
    "session_id",
    "run_id",
    "started_at_unix",
    "ended_at_unix",
    "device",
    "summary",
    "frames",
)


def _validate_manifest(manifest: dict, expected_session_id: str) -> tuple[bool, str | None, Any]:
    for f in _REQUIRED_SESSION_FIELDS:
        if f not in manifest:
            return False, "manifest_missing_field", f
    if manifest.get("session_id") != expected_session_id:
        return False, "manifest_session_mismatch", manifest.get("session_id")
    frames = manifest.get("frames")
    if not isinstance(frames, list) or not frames:
        return False, "manifest_no_frames", None
    bad: list[dict] = []
    for fr in frames:
        if not isinstance(fr, dict):
            bad.append({"reason": "not_object"})
            continue
        for k in _REQUIRED_FRAME_FIELDS:
            if k not in fr:
                bad.append({"frame_id": fr.get("frame_id"), "missing": k})
                break
    if bad:
        return False, "manifest_bad_frames", bad[:25]
    return True, None, None


def _referenced_paths(manifest: dict) -> set[str]:
    """Every relative path the manifest claims will be in the upload."""
    out: set[str] = set()
    for fr in manifest.get("frames", []):
        ip = fr.get("image_path")
        if isinstance(ip, str):
            out.add(ip)
        for k in ("scene_depth_path", "smoothed_scene_depth_path"):
            v = fr.get(k)
            if isinstance(v, str):
                out.add(v)
    return out


# ---------------------------------------------------------------------------
# Server / handler
# ---------------------------------------------------------------------------


class _CaptureServer(ThreadingHTTPServer):
    """ThreadingHTTPServer with attached session + completion event."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        addr: tuple[str, int],
        handler_cls: type[BaseHTTPRequestHandler],
        *,
        session: CaptureSession,
        completion_event: threading.Event,
        max_upload_bytes: int = DEFAULT_MAX_UPLOAD_BYTES,
    ) -> None:
        super().__init__(addr, handler_cls)
        self.session = session
        self.completion_event = completion_event
        self.max_upload_bytes = max_upload_bytes
        self.upload_result: UploadResult | None = None
        self._already_received = False
        self._lock = threading.Lock()

    def claim_upload(self) -> bool:
        """Return True iff this caller wins the race to handle /upload."""
        with self._lock:
            if self._already_received:
                return False
            self._already_received = True
            return True


class _Handler(BaseHTTPRequestHandler):
    server: _CaptureServer  # type: ignore[assignment]

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        # Route through logging instead of stderr.
        log.info("%s - %s", self.address_string(), fmt % args)

    # ---------------- GET ----------------

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path == "/healthz":
            _text_response(self, HTTPStatus.OK, "ok")
            return
        if path == "/session":
            _json_response(self, HTTPStatus.OK, self.server.session.to_descriptor())
            return
        if path == "/tutorial-config":
            qs = urllib.parse.parse_qs(parsed.query)
            scene = (qs.get("scene_type") or [self.server.session.scene_type])[0]
            _json_response(self, HTTPStatus.OK, scene_tip_set(scene))
            return
        if path == "/join":
            html = self._join_page()
            _text_response(self, HTTPStatus.OK, html, content_type="text/html; charset=utf-8")
            return
        if path == "/" or path == "":
            _text_response(self, HTTPStatus.OK, "ClaudeSplat capture session active.\n")
            return
        _json_response(self, HTTPStatus.NOT_FOUND, {"error": "not_found", "path": path})

    def _join_page(self) -> str:
        s = self.server.session
        scenes_html = ", ".join(SCENE_TYPES)
        return f"""<!doctype html>
<html><head><meta name="viewport" content="width=device-width, initial-scale=1">
<title>ClaudeSplat capture</title>
<style>
  body{{font-family:-apple-system,Helvetica,Arial,sans-serif;padding:24px;line-height:1.4;}}
  code{{background:#f0f0f0;padding:2px 6px;border-radius:4px;}}
</style></head>
<body>
  <h2>Capture session active</h2>
  <p>Session: <code>{s.session_id}</code></p>
  <p>Run: <code>{s.run_id}</code></p>
  <p>Open the <strong>ClaudeSplat</strong> app on this iPhone to continue.
     If the app is not installed yet, this session is reachable directly
     for development.</p>
  <p>Scene types supported: <small>{scenes_html}</small></p>
</body></html>"""

    # ---------------- POST ----------------

    def do_POST(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/upload":
            _json_response(
                self,
                HTTPStatus.NOT_FOUND,
                {"error": "not_found", "path": parsed.path},
            )
            return
        if not self.server.claim_upload():
            _json_response(
                self,
                HTTPStatus.CONFLICT,
                {"error": "session_already_received"},
            )
            return
        try:
            result = self._handle_upload()
        except Exception as e:  # noqa: BLE001
            log.exception("upload failed")
            self.server.upload_result = UploadResult(ok=False, error="server_exception", detail=repr(e))
            _json_response(
                self,
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"error": "server_exception", "detail": repr(e)},
            )
            self.server.completion_event.set()
            return

        self.server.upload_result = result
        if result.ok:
            _json_response(
                self,
                HTTPStatus.OK,
                {
                    "ok": True,
                    "run_id": self.server.session.run_id,
                    "frames_received": result.frames_received,
                    "depth_received": result.depth_received,
                    "tracking_state_breakdown": result.tracking_state_breakdown or {},
                },
            )
        else:
            _json_response(
                self,
                HTTPStatus.BAD_REQUEST,
                {"error": result.error, "detail": result.detail},
            )
        self.server.completion_event.set()

    def _handle_upload(self) -> UploadResult:
        s = self.server.session
        ctype = self.headers.get("Content-Type", "")
        if not ctype.lower().startswith("multipart/form-data"):
            return UploadResult(ok=False, error="content_type_not_multipart", detail=ctype)

        clen_hdr = self.headers.get("Content-Length")
        if clen_hdr is None:
            return UploadResult(ok=False, error="content_length_required")
        try:
            clen = int(clen_hdr)
        except ValueError:
            return UploadResult(ok=False, error="content_length_invalid")
        if clen > self.server.max_upload_bytes:
            return UploadResult(
                ok=False,
                error="payload_too_large",
                detail={"limit": self.server.max_upload_bytes, "got": clen},
            )

        # cgi.FieldStorage handles streaming multipart parsing without
        # buffering the whole body in RAM. Files spill to /tmp.
        environ = {
            "REQUEST_METHOD": "POST",
            "CONTENT_TYPE": ctype,
            "CONTENT_LENGTH": str(clen),
        }
        # max_num_fields guard (Python ≥3.10) blocks DoS via huge field counts.
        try:
            form = cgi.FieldStorage(  # type: ignore[call-arg]
                fp=self.rfile,
                headers=self.headers,
                environ=environ,
                keep_blank_values=True,
                strict_parsing=False,
                max_num_fields=200_000,
            )
        except Exception as e:  # noqa: BLE001
            return UploadResult(ok=False, error="multipart_parse", detail=repr(e))

        # session_id check
        sid_field = form.getfirst("session_id")
        if sid_field != s.session_id:
            return UploadResult(
                ok=False,
                error="session_id_mismatch",
                detail={"expected": s.session_id, "got": sid_field},
            )

        # manifest
        manifest_item = form["manifest"] if "manifest" in form else None
        if manifest_item is None or not getattr(manifest_item, "file", None):
            return UploadResult(ok=False, error="manifest_missing")
        try:
            raw = manifest_item.file.read()
            if isinstance(raw, bytes):
                raw = raw.decode("utf-8")
            manifest = json.loads(raw)
        except Exception as e:  # noqa: BLE001
            return UploadResult(ok=False, error="manifest_parse", detail=repr(e))

        ok, err, detail = _validate_manifest(manifest, expected_session_id=s.session_id)
        if not ok:
            return UploadResult(ok=False, error=err, detail=detail)

        # Persist files. Manifest paths are AUTHORITATIVE — every part
        # filename must match a manifest reference, and every manifest
        # reference must be present.
        capture_dir = s.run_dir / "capture"
        capture_dir.mkdir(parents=True, exist_ok=True)

        referenced = _referenced_paths(manifest)
        seen_paths: set[str] = set()
        write_errors: list[str] = []

        for field_name, subdir in _FRAME_PART_DIRS.items():
            items = form[field_name] if field_name in form else None
            if items is None:
                continue
            entries = items if isinstance(items, list) else [items]
            for item in entries:
                if not getattr(item, "file", None):
                    continue
                fname = item.filename or ""
                # If the iOS app sends bare names, prepend the expected dir.
                rel = fname if "/" in fname else f"{subdir}/{fname}"
                safe = _safe_relpath(rel)
                if safe is None:
                    write_errors.append(f"unsafe_path:{rel}")
                    continue
                if safe not in referenced:
                    write_errors.append(f"unreferenced:{safe}")
                    continue
                target = capture_dir / safe
                target.parent.mkdir(parents=True, exist_ok=True)
                with open(target, "wb") as out:
                    shutil.copyfileobj(item.file, out)
                seen_paths.add(safe)

        missing = sorted(referenced - seen_paths)
        if write_errors or missing:
            return UploadResult(
                ok=False,
                error="upload_payload_mismatch",
                detail={
                    "errors": write_errors[:25],
                    "missing": missing[:25],
                },
            )

        # Save the manifest itself.
        (capture_dir / "manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n",
            encoding="utf-8",
        )

        # Optional flat parts (single-file each).
        for single_field, single_target in (
            ("mesh", "scene_mesh"),  # extension preserved
            ("thumbnail", "thumbnail.jpg"),
        ):
            item = form[single_field] if single_field in form else None
            if item is not None and getattr(item, "file", None):
                fname = item.filename or single_target
                if single_field == "mesh":
                    ext = os.path.splitext(fname)[1] or ".bin"
                    target = capture_dir / f"scene_mesh{ext}"
                else:
                    target = capture_dir / single_target
                with open(target, "wb") as out:
                    shutil.copyfileobj(item.file, out)

        # Tally stats from manifest.
        tracking_breakdown: dict[str, int] = {}
        for fr in manifest.get("frames", []):
            ts = fr.get("tracking_state", "unknown")
            tracking_breakdown[ts] = tracking_breakdown.get(ts, 0) + 1

        depth_received = sum(1 for p in seen_paths if p.startswith("depth/"))
        smoothed_received = sum(1 for p in seen_paths if p.startswith("depth_smoothed/"))
        frames_received = sum(1 for p in seen_paths if p.startswith("frames/"))

        return UploadResult(
            ok=True,
            frames_received=frames_received,
            depth_received=depth_received,
            smoothed_depth_received=smoothed_received,
            tracking_state_breakdown=tracking_breakdown,
        )


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def start_server(
    session: CaptureSession,
    *,
    completion_event: threading.Event | None = None,
    max_upload_bytes: int = DEFAULT_MAX_UPLOAD_BYTES,
) -> tuple[_CaptureServer, threading.Thread, threading.Event]:
    """Start the capture server in a background thread.

    Returns (server, thread, completion_event). Caller is responsible for
    stopping via `server.shutdown()` and joining the thread.
    """
    event = completion_event or threading.Event()
    addr = ("0.0.0.0", session.port)
    srv = _CaptureServer(
        addr,
        _Handler,
        session=session,
        completion_event=event,
        max_upload_bytes=max_upload_bytes,
    )
    th = threading.Thread(target=srv.serve_forever, name="ar-layer0-server", daemon=True)
    th.start()
    return srv, th, event


def stop_server(srv: _CaptureServer, th: threading.Thread) -> None:
    try:
        srv.shutdown()
    finally:
        srv.server_close()
        th.join(timeout=3.0)
