"""AR-Layer 0 orchestrator — public entry point for the dispatcher.

Flow:
  1) Prompt for a video name + scene type (or accept via kwargs).
  2) Allocate ar_runs/run<N>__<slug>/, write capture_session.json.
  3) Start local HTTP server on a background thread.
  4) Display QR (ASCII + PNG) with deep-link + http fallback.
  5) Block on completion_event with timeout, allowing Ctrl+C.
  6) On success: write capture_manifest.json summary, shut down, return run_dir.
  7) On timeout / cancel: shut down, leave run_dir on disk for inspection.
"""

from __future__ import annotations

import json
import logging
import sys
import time
from pathlib import Path
from typing import Any

from .qr import display_session_qrs
from .scene_types import SCENE_TYPES
from .server import start_server, stop_server
from .session import CaptureSession, new_session


log = logging.getLogger("ar_layer0")


def _setup_logging(run_dir: Path) -> None:
    log_file = run_dir / "logs" / "layer0.log"
    log_file.parent.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s")
    fh = logging.FileHandler(log_file, encoding="utf-8")
    fh.setFormatter(fmt)
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    # Keep prior handlers so the upload pipeline's logger keeps working.
    root.addHandler(fh)
    if not any(isinstance(h, logging.StreamHandler) for h in root.handlers):
        root.addHandler(sh)


def _prompt_video_name() -> str:
    while True:
        try:
            raw = input("Name this capture (used for the run folder): ").strip()
        except EOFError:
            print("\nAborted.", file=sys.stderr)
            sys.exit(1)
        if raw:
            return raw
        print("Please enter a non-empty name.")


def _prompt_scene_type(default: str = "room") -> str:
    print("\nScene type — picks the tutorial tip set:")
    for i, name in enumerate(SCENE_TYPES, 1):
        marker = "  *" if name == default else "   "
        print(f" {marker}{i:2}) {name}")
    try:
        raw = input(f"Choose [1-{len(SCENE_TYPES)}, default={default}]: ").strip()
    except EOFError:
        return default
    if not raw:
        return default
    if raw.isdigit():
        n = int(raw)
        if 1 <= n <= len(SCENE_TYPES):
            return SCENE_TYPES[n - 1]
    if raw in SCENE_TYPES:
        return raw
    print(f"Unknown choice; defaulting to {default}.")
    return default


def _write_session_metadata(session: CaptureSession) -> Path:
    path = session.run_dir / "metadata" / "capture_session.json"
    path.write_text(
        json.dumps(session.to_session_metadata(), indent=2) + "\n",
        encoding="utf-8",
    )
    return path


def _write_manifest_summary(session: CaptureSession, result_summary: dict[str, Any]) -> Path:
    path = session.run_dir / "metadata" / "capture_manifest.json"
    path.write_text(
        json.dumps(
            {
                "session_id": session.session_id,
                "run_id": session.run_id,
                "received_at_unix": time.time(),
                "summary": result_summary,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return path


def run_layer0(
    *,
    video_name: str | None = None,
    scene_type: str | None = None,
    timeout_seconds: int = 900,
    ar_runs_root: Path | None = None,
    interactive: bool = True,
    open_qr_png: bool = True,
) -> Path | None:
    """Run AR capture session. Returns the run_dir on success, None on cancel.

    On success, ar_runs/<run_id>/ contains:
      capture/manifest.json, capture/frames/*.jpg, capture/depth/*.bin (opt),
      metadata/capture_session.json, metadata/capture_manifest.json,
      logs/layer0.log
    """
    if video_name is None:
        if not interactive:
            raise ValueError("video_name required in non-interactive mode")
        video_name = _prompt_video_name()
    if scene_type is None:
        scene_type = _prompt_scene_type() if interactive else "room"

    session = new_session(
        video_name=video_name,
        scene_type=scene_type,
        timeout_seconds=timeout_seconds,
        ar_runs_root=ar_runs_root,
    )
    _setup_logging(session.run_dir)
    log.info("AR capture session %s allocated at %s", session.session_id, session.run_dir)
    _write_session_metadata(session)

    srv, th, event = start_server(session)
    try:
        display_session_qrs(
            deep_link=session.deep_link,
            http_url=session.join_url,
            out_dir=session.run_dir / "capture",
            open_png=open_qr_png,
        )
        print(f"Session id : {session.session_id}")
        print(f"Run id     : {session.run_id}")
        print(f"Run dir    : {session.run_dir}")
        print(f"Listening  : {session.http_url}")
        print(f"Timeout    : {timeout_seconds}s "
              f"(also stops on Ctrl+C)")
        print()
        print("Waiting for capture upload...")

        deadline = session.expires_at
        try:
            while not event.is_set():
                remaining = deadline - time.time()
                if remaining <= 0:
                    print("\nTimed out waiting for capture upload.")
                    return None
                event.wait(timeout=min(1.0, remaining))
        except KeyboardInterrupt:
            print("\nCancelled by user.")
            return None

        result = srv.upload_result
        if result is None or not result.ok:
            err = (result.error if result else "unknown") or "unknown"
            detail = result.detail if result else None
            print(f"\nUpload failed: {err}")
            if detail:
                print(json.dumps(detail, indent=2))
            log.error("upload failed: %s detail=%s", err, detail)
            return None

        summary = {
            "frames_received": result.frames_received,
            "depth_received": result.depth_received,
            "smoothed_depth_received": result.smoothed_depth_received,
            "tracking_state_breakdown": result.tracking_state_breakdown or {},
        }
        _write_manifest_summary(session, summary)

        print()
        print(f"Capture received: {result.frames_received} frames, "
              f"depth={result.depth_received}, "
              f"tracking={result.tracking_state_breakdown}")
        print(f"Run dir: {session.run_dir}")
        return session.run_dir
    finally:
        stop_server(srv, th)


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="AR-Layer 0 capture session.")
    parser.add_argument("--video-name", type=str, default=None)
    parser.add_argument(
        "--scene-type",
        type=str,
        default=None,
        choices=SCENE_TYPES + [None],  # type: ignore[arg-type]
    )
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--ar-runs-root", type=Path, default=None)
    parser.add_argument("--no-open-png", action="store_true")
    parser.add_argument("--non-interactive", action="store_true")
    args = parser.parse_args()

    out = run_layer0(
        video_name=args.video_name,
        scene_type=args.scene_type,
        timeout_seconds=args.timeout,
        ar_runs_root=args.ar_runs_root,
        interactive=not args.non_interactive,
        open_qr_png=not args.no_open_png,
    )
    if out is None:
        sys.exit(2)
    print(out)


if __name__ == "__main__":
    main()
