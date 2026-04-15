#!/usr/bin/env python3
"""
Baseline orchestrator (Layer 0): one run root, predictable subfolders, metadata + logs.

Stages:
  1. input/input.mp4 — canonical copy of the source video
  2. extract — frames under images/ (then COLMAP renames to source/)
  3. colmap — database, sparse, undistortion via scripts/run_glomap.py
  4. outputs/splat/ — reserved for exported .ply (Brush or manual)
  5. metadata/run_metadata.json — updated after each stage

Usage (from repo root):
  python -m pipeline.run_pipeline
      # prompts you to pick a file under Videos_Dataset/
  python -m pipeline.run_pipeline --video path/to/movie.mp4
  python -m pipeline.run_pipeline --dataset-dir /path/to/folder   # pick from that folder
"""

from __future__ import annotations

import argparse
import json
import logging
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

# Import existing stage scripts (no package under scripts/).
_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(_ROOT / "scripts"))

import run_glomap  # noqa: E402
import video_to_demo_frames  # noqa: E402

# Layer 2 lives under scripts/layer2/
_LAYER2_ROOT = _ROOT / "scripts"
if str(_LAYER2_ROOT) not in sys.path:
    sys.path.insert(0, str(_LAYER2_ROOT))
from layer2.run_layer2 import run_layer2  # noqa: E402
from layer3.run_layer3 import run_layer3  # noqa: E402
from layer4.run_layer4 import run_layer4  # noqa: E402

from .config import PipelineConfig, default_brush_app_binary, repo_root  # noqa: E402

VIDEO_SUFFIXES = frozenset({".mp4", ".mov", ".mkv", ".avi", ".webm", ".m4v"})


def _is_video_file(path: Path) -> bool:
    return path.suffix.lower() in VIDEO_SUFFIXES


def discover_videos(dataset_dir: Path) -> list[Path]:
    """Return sorted video files directly under dataset_dir (not recursive)."""
    dataset_dir = dataset_dir.resolve()
    if not dataset_dir.is_dir():
        return []
    found: list[Path] = []
    for p in dataset_dir.iterdir():
        if p.is_file() and _is_video_file(p):
            found.append(p)
    return sorted(found, key=lambda x: x.name.lower())


def pick_video_interactive(dataset_dir: Path) -> Path:
    """Print a numbered list and read a choice from stdin."""
    dataset_dir = dataset_dir.resolve()
    if not dataset_dir.is_dir():
        raise FileNotFoundError(
            f"Video dataset folder does not exist: {dataset_dir}\n"
            "Create it, add videos, or pass --dataset-dir / --video."
        )
    files = discover_videos(dataset_dir)
    if not files:
        raise FileNotFoundError(
            f"No video files found in {dataset_dir}\n"
            f"(extensions: {', '.join(sorted(VIDEO_SUFFIXES))})\n"
            "Add clips or run with --video PATH."
        )
    print(f"\nVideos in {dataset_dir}:\n")
    for i, p in enumerate(files, 1):
        print(f"  {i:3})  {p.name}")
    print()
    while True:
        try:
            raw = input("Enter number to run the pipeline on that video (q to quit): ").strip()
        except EOFError:
            print("\nAborted.", file=sys.stderr)
            sys.exit(1)
        if not raw:
            continue
        if raw.lower() in ("q", "quit", "exit"):
            print("Aborted.")
            sys.exit(0)
        if raw.isdigit():
            n = int(raw)
            if 1 <= n <= len(files):
                chosen = files[n - 1]
                print(f"\nSelected: {chosen.name}\n")
                return chosen
        print(f"Enter a number from 1 to {len(files)}, or q to quit.")


def _prompt_int(prompt: str, *, default: int | None = None, min_value: int | None = None) -> int:
    while True:
        d = f"[{default}]" if default is not None else ""
        raw = input(f"{prompt} {d}: ").strip()
        if not raw and default is not None:
            val = default
        else:
            try:
                val = int(raw)
            except ValueError:
                print("Enter an integer.")
                continue
        if min_value is not None and val < min_value:
            print(f"Must be >= {min_value}.")
            continue
        return val


def _prompt_float(prompt: str, *, default: float | None = None, min_value: float | None = None) -> float:
    while True:
        d = f"[{default}]" if default is not None else ""
        raw = input(f"{prompt} {d}: ").strip()
        if not raw and default is not None:
            val = default
        else:
            try:
                val = float(raw)
            except ValueError:
                print("Enter a number.")
                continue
        if min_value is not None and val < min_value:
            print(f"Must be >= {min_value}.")
            continue
        return val


def ingest_menu_defaults(cfg: PipelineConfig) -> PipelineConfig:
    """
    Interactive menu for Layer 1 options (recommended defaults).
    Mutates a shallow copy of cfg and returns it.
    """
    print("Ingest options (Layer 1). Press Enter to accept defaults.\n")
    print("Resize:")
    print("  1) No resize (recommended default)")
    print("  2) Resize width to 1280 (keep aspect)")
    print("  3) Resize width to 1920 (keep aspect)")
    print("  4) Custom resize")
    choice = input("Select resize option [1]: ").strip() or "1"
    if choice == "1":
        cfg.resize_width = None
        cfg.resize_height = None
    elif choice == "2":
        cfg.resize_width = 1280
        cfg.resize_height = None
    elif choice == "3":
        cfg.resize_width = 1920
        cfg.resize_height = None
    elif choice == "4":
        w = input("Resize width (blank to keep aspect): ").strip()
        h = input("Resize height (blank to keep aspect): ").strip()
        cfg.resize_width = int(w) if w else None
        cfg.resize_height = int(h) if h else None
    else:
        print("Invalid choice; using default (no resize).")
        cfg.resize_width = None
        cfg.resize_height = None

    print("\nFrame-rate reduction:")
    print("  1) Cap to max frames (recommended default)")
    print("  2) Keep all frames")
    print("  3) Target FPS (ffmpeg fps filter)")
    choice = input("Select frame-rate option [1]: ").strip() or "1"
    if choice == "1":
        cfg.keep_all_frames = False
        cfg.max_frames = _prompt_int("Max frames", default=cfg.max_frames, min_value=1)
        cfg.target_fps = None
    elif choice == "2":
        cfg.keep_all_frames = True
        cfg.target_fps = None
    elif choice == "3":
        cfg.keep_all_frames = True
        cfg.target_fps = _prompt_float("Target FPS", default=5.0, min_value=0.01)
    else:
        print("Invalid choice; using default (cap to max frames).")
        cfg.keep_all_frames = False
        cfg.target_fps = None

    print()
    return cfg


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _safe_run_id_fragment(name: str, max_len: int = 48) -> str:
    out = []
    for c in name:
        if c.isalnum() or c in ("-", "_", "."):
            out.append(c)
        elif c in (" ",):
            out.append("_")
        else:
            out.append("_")
    s = "".join(out).strip("._")
    return (s[:max_len] if s else "video") or "video"


def default_run_id(video_path: Path) -> str:
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{ts}_{_safe_run_id_fragment(video_path.stem)}"


def write_metadata(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    tmp.replace(path)


def setup_logging(log_file: Path) -> None:
    log_file.parent.mkdir(parents=True, exist_ok=True)
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    for h in root.handlers[:]:
        root.removeHandler(h)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    fh = logging.FileHandler(log_file, encoding="utf-8")
    fh.setFormatter(fmt)
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    root.addHandler(fh)
    root.addHandler(sh)


def _find_exported_splat(run_dir: Path) -> str | None:
    out = run_dir / "outputs" / "splat"
    if not out.is_dir():
        return None
    for pattern in ("*.ply", "*.compressed.ply"):
        matches = sorted(out.glob(pattern))
        if matches:
            return str(matches[-1].resolve())
    return None


def run_pipeline(
    video_path: Path,
    *,
    run_id: str | None,
    cfg: PipelineConfig,
    video_selection: Literal["cli", "interactive"] = "cli",
) -> Path:
    video_path = video_path.resolve()
    if not video_path.is_file():
        raise FileNotFoundError(video_path)

    cfg.validate()
    rid = run_id or default_run_id(video_path)
    run_dir = (cfg.runs_root / rid).resolve()
    if run_dir.exists():
        raise FileExistsError(f"Run directory already exists: {run_dir}")

    input_dir = run_dir / "input"
    meta_dir = run_dir / "metadata"
    logs_dir = run_dir / "logs"
    outputs_splat = run_dir / "outputs" / "splat"

    input_dir.mkdir(parents=True)
    meta_dir.mkdir(parents=True)
    logs_dir.mkdir(parents=True)
    outputs_splat.mkdir(parents=True)

    canonical_video = input_dir / "input.mp4"
    shutil.copy2(video_path, canonical_video)

    meta_path = meta_dir / "run_metadata.json"
    metadata: dict[str, Any] = {
        "run_id": rid,
        "schema_version": 1,
        "created_at": _utc_now(),
        "status": "running",
        "video_selection": video_selection,
        "config": {
            "max_frames": cfg.max_frames,
            "keep_all_frames": cfg.keep_all_frames,
            "resize_width": cfg.resize_width,
            "resize_height": cfg.resize_height,
            "target_fps": cfg.target_fps,
            "matcher_type": cfg.matcher_type,
            "interval": cfg.interval,
            "model_type": cfg.model_type,
            "copy_video_into_run": cfg.copy_video_into_run,
            "run_brush": cfg.run_brush,
            "brush_binary": str(cfg.brush_binary) if cfg.brush_binary else None,
            "brush_total_steps": cfg.brush_total_steps,
            "brush_headless": cfg.brush_headless,
            # Layer 2
            "run_layer2": cfg.run_layer2,
            "blur_threshold": cfg.blur_threshold,
            "exposure_threshold": cfg.exposure_threshold,
            "hamming_threshold": cfg.hamming_threshold,
            "motion_floor": cfg.motion_floor,
            "min_keep_frames": cfg.min_keep_frames,
            # Layer 3
            "run_layer3": cfg.run_layer3,
            "layer3_halt_on_critical": cfg.layer3_halt_on_critical,
            # Layer 4
            "run_layer4": cfg.run_layer4,
            "depth_model": cfg.depth_model,
            # COLMAP auto-matcher
            "auto_select_matcher": cfg.auto_select_matcher,
            "exhaustive_threshold": cfg.exhaustive_threshold,
            "sequential_overlap": cfg.sequential_overlap,
            # COLMAP profile
            "colmap_profile": cfg.colmap_profile,
        },
        "paths": {
            "repo_root": str(_ROOT),
            "dataset_dir": str(video_path.parent.resolve()) if video_selection == "interactive" else None,
            "run_root": str(run_dir),
            "input_video": str(canonical_video.resolve()),
            "source_video_original": str(video_path),
            "logs_dir": str(logs_dir.resolve()),
            "metadata_dir": str(meta_dir.resolve()),
            "frames_dir": str((run_dir / "images").resolve()),
            "source_images_dir": str((run_dir / "source").resolve()),
            "colmap_distorted": str((run_dir / "distorted").resolve()),
            "colmap_sparse": str((run_dir / "sparse" / "0").resolve()),
            "colmap_log": str((run_dir / "colmap_run.log").resolve()),
            "brush_training_root": str(run_dir.resolve()),
            "outputs_splat_dir": str(outputs_splat.resolve()),
            "final_splat": None,
        },
        "stages": {},
        "errors": None,
    }
    write_metadata(meta_path, metadata)

    setup_logging(logs_dir / "pipeline.log")
    log = logging.getLogger("pipeline")

    def _stage(name: str, fn, *args, **kwargs) -> Any:
        t0 = time.perf_counter()
        metadata["stages"][name] = {
            "status": "running",
            "started_at": _utc_now(),
        }
        write_metadata(meta_path, metadata)
        try:
            result = fn(*args, **kwargs)
        except Exception as e:
            metadata["stages"][name]["status"] = "failed"
            metadata["stages"][name]["ended_at"] = _utc_now()
            metadata["stages"][name]["error"] = repr(e)
            metadata["status"] = "failed"
            metadata["errors"] = {"stage": name, "message": str(e)}
            write_metadata(meta_path, metadata)
            log.exception("Stage %s failed", name)
            raise
        elapsed = time.perf_counter() - t0
        metadata["stages"][name]["status"] = "completed"
        metadata["stages"][name]["ended_at"] = _utc_now()
        metadata["stages"][name]["seconds"] = round(elapsed, 3)
        if result is not None:
            metadata["stages"][name]["metrics"] = result
        write_metadata(meta_path, metadata)
        log.info("Stage %s completed in %.2fs", name, elapsed)
        return result

    # 1) Frames: use run_dir as demo_dir so COLMAP layout stays under one tree.
    def _extract():
        for bin_name in ("ffmpeg", "ffprobe"):
            if shutil.which(bin_name) is None:
                raise RuntimeError(f"'{bin_name}' not found on PATH; install ffmpeg.")
        return video_to_demo_frames.extract_video_to_images(
            canonical_video,
            run_dir,
            max_frames=cfg.max_frames,
            keep_all_frames=cfg.keep_all_frames,
            resize_width=cfg.resize_width,
            resize_height=cfg.resize_height,
            target_fps=cfg.target_fps,
            copy_source_video=cfg.copy_video_into_run,
        )

    _stage("extract", _extract)
    metadata["paths"]["frames_dir"] = str((run_dir / "images").resolve())
    write_metadata(meta_path, metadata)

    # 1b) Layer 2: frame quality scoring and keyframe selection.
    images_dir = run_dir / "images"
    if cfg.run_layer2:
        def _layer2():
            return run_layer2(
                images_dir,
                blur_threshold=cfg.blur_threshold,
                exposure_threshold=cfg.exposure_threshold,
                hamming_threshold=cfg.hamming_threshold,
                motion_floor=cfg.motion_floor,
                min_keep_frames=cfg.min_keep_frames,
                verbose=True,
            )
        _stage("layer2_quality", _layer2)
        metadata["paths"]["rejected_frames_dir"] = str((run_dir / "images_rejected").resolve())
        write_metadata(meta_path, metadata)
    else:
        metadata["stages"]["layer2_quality"] = {
            "status": "skipped",
            "reason": "run_layer2 false (--skip-layer2)",
        }
        write_metadata(meta_path, metadata)
        log.info("Layer 2 skipped (--skip-layer2).")

    # 1c) Layer 3: pre-COLMAP dataset audit.
    _l2_stats = metadata.get("stages", {}).get("layer2_quality", {}).get("metrics")
    if cfg.run_layer3:
        def _layer3():
            return run_layer3(
                images_dir,
                layer2_stats=_l2_stats,
                verbose=True,
                halt_on_critical=cfg.layer3_halt_on_critical,
            )
        _stage("layer3_audit", _layer3)
        metadata["paths"]["layer3_audit"] = str(
            (run_dir / "metadata" / "layer3_audit.json").resolve()
        )
        write_metadata(meta_path, metadata)
    else:
        metadata["stages"]["layer3_audit"] = {
            "status": "skipped",
            "reason": "run_layer3 false (--skip-layer3)",
        }
        write_metadata(meta_path, metadata)
        log.info("Layer 3 skipped (--skip-layer3).")

    # 1d) Layer 4: monocular depth map generation (dpt/ folder for Brush).
    if cfg.run_layer4:
        def _layer4():
            return run_layer4(
                images_dir,
                model_type=cfg.depth_model,
                verbose=True,
                skip_existing=True,
            )
        _stage("layer4_depth", _layer4)
        metadata["paths"]["dpt_dir"] = str((run_dir / "dpt").resolve())
        write_metadata(meta_path, metadata)
    else:
        metadata["stages"]["layer4_depth"] = {
            "status": "skipped",
            "reason": "run_layer4 false (--skip-layer4)",
        }
        write_metadata(meta_path, metadata)
        log.info("Layer 4 skipped (--skip-layer4).")

    # 2) COLMAP expects the folder named images/ initially (then renames to source/).
    if not images_dir.is_dir():
        raise FileNotFoundError(f"Expected frames at {images_dir}")

    def _colmap():
        # Resolve layer3 audit path for auto-profile selection
        _audit_path = run_dir / "metadata" / "layer3_audit.json"
        run_glomap.run_colmap(
            str(images_dir),
            cfg.matcher_type,
            cfg.interval,
            cfg.model_type,
            auto_select_matcher=cfg.auto_select_matcher,
            sequential_overlap=cfg.sequential_overlap,
            exhaustive_threshold=cfg.exhaustive_threshold,
            profile_name=cfg.colmap_profile,
            layer3_audit_path=str(_audit_path) if _audit_path.exists() else None,
        )
        return {}

    _stage("colmap", _colmap)

    # Refresh path hints after COLMAP mutates layout (images/ -> source/).
    if (run_dir / "source").is_dir():
        metadata["paths"]["frames_dir"] = str((run_dir / "source").resolve())
        metadata["paths"]["source_images_dir"] = str((run_dir / "source").resolve())
    elif (run_dir / "images").is_dir():
        metadata["paths"]["frames_dir"] = str((run_dir / "images").resolve())
    metadata["paths"]["colmap_database"] = str((run_dir / "distorted" / "database.db").resolve())
    metadata["paths"]["colmap_database_global"] = str(
        (run_dir / "distorted" / "database_global.db").resolve()
    )
    splat = _find_exported_splat(run_dir)
    metadata["paths"]["final_splat"] = splat

    # 3) Brush (headless): COLMAP run root is the dataset path (images/ + sparse/0/).
    brush_bin: Path | None = None
    if cfg.brush_binary is not None:
        brush_bin = cfg.brush_binary.resolve()
    else:
        brush_bin = default_brush_app_binary(_ROOT)

    if cfg.run_brush:
        if brush_bin is None or not brush_bin.is_file():
            metadata["stages"]["brush"] = {
                "status": "skipped",
                "reason": "brush_app not found",
                "hint": (
                    "Build Brush: cd brush && cargo build --release "
                    f"(expect {_ROOT / 'brush' / 'target' / 'release' / 'brush_app'}) "
                    "or pass --brush-binary PATH. Use --skip-brush to skip this stage."
                ),
            }
            write_metadata(meta_path, metadata)
            log.warning(
                "Brush stage skipped: no brush_app at %s. COLMAP outputs are in %s",
                brush_bin or (_ROOT / "brush" / "target" / "release" / "brush_app"),
                run_dir,
            )
        else:
            metadata["paths"]["brush_binary"] = str(brush_bin)

            def _brush() -> dict[str, Any]:
                import subprocess

                steps = int(cfg.brush_total_steps)
                # Dataset path first. Omit --with-viewer → headless; pass --with-viewer → GUI (no value after flag).
                cmd = [
                    str(brush_bin),
                    str(run_dir.resolve()),
                ]
                if not cfg.brush_headless:
                    cmd.append("--with-viewer")
                cmd.extend(
                    [
                        "--export-path",
                        str(outputs_splat.resolve()),
                        "--export-every",
                        str(steps),
                        "--total-steps",
                        str(steps),
                    ]
                )
                log.info("Starting Brush: %s", " ".join(cmd))
                r = subprocess.run(cmd, cwd=str(run_dir), check=False)
                if r.returncode != 0:
                    raise RuntimeError(f"Brush exited with code {r.returncode}")
                return {
                    "command": cmd,
                    "total_steps": steps,
                    "brush_headless": cfg.brush_headless,
                }

            _stage("brush", _brush)
    else:
        metadata["stages"]["brush"] = {
            "status": "skipped",
            "reason": "run_brush false (--skip-brush)",
            "hint": f"Open {run_dir} in Brush manually if you want training.",
        }
        write_metadata(meta_path, metadata)

    splat = _find_exported_splat(run_dir)
    metadata["paths"]["final_splat"] = splat
    metadata["status"] = "completed"
    metadata["completed_at"] = _utc_now()
    write_metadata(meta_path, metadata)
    log.info("Run complete: %s", run_dir)
    return run_dir


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--video",
        type=Path,
        default=None,
        help=(
            "Source video file (copied to run input/input.mp4). "
            "If omitted, you are prompted to choose from --dataset-dir."
        ),
    )
    parser.add_argument(
        "--dataset-dir",
        type=Path,
        default=None,
        help=f"Folder to list when choosing interactively (default: {repo_root() / 'Videos_Dataset'}).",
    )
    parser.add_argument(
        "--run-id",
        type=str,
        default=None,
        help="Run folder name under runs/ (default: timestamp + video stem).",
    )
    parser.add_argument(
        "--runs-root",
        type=Path,
        default=None,
        help=f"Parent for all runs (default: {repo_root() / 'runs'}).",
    )
    parser.add_argument("--max-frames", type=int, default=250)
    parser.add_argument(
        "--no-ingest-menu",
        action="store_true",
        help="Do not prompt for ingest options; use defaults / CLI flags.",
    )
    parser.add_argument("--keep-all-frames", action="store_true", help="Ingest: export every frame.")
    parser.add_argument("--resize-width", type=int, default=None, help="Ingest: resize width (keep aspect if height omitted).")
    parser.add_argument("--resize-height", type=int, default=None, help="Ingest: resize height (keep aspect if width omitted).")
    parser.add_argument("--target-fps", type=float, default=None, help="Ingest: target FPS with ffmpeg fps filter.")
    parser.add_argument(
        "--matcher-type",
        default="sequential_matcher",
        choices=["sequential_matcher", "exhaustive_matcher"],
    )
    parser.add_argument("--interval", type=int, default=1)
    parser.add_argument("--model-type", default="3dgs", choices=["3dgs", "nerfstudio"])
    parser.add_argument(
        "--copy-video-beside-frames",
        action="store_true",
        help="Also copy the source video to the run root (in addition to input/input.mp4).",
    )
    parser.add_argument(
        "--skip-brush",
        action="store_true",
        help="Do not run Brush after COLMAP (default: run when brush_app exists).",
    )
    parser.add_argument(
        "--brush-binary",
        type=Path,
        default=None,
        help="Path to brush_app (default: brush/target/release/brush_app under repo root).",
    )
    parser.add_argument(
        "--brush-total-steps",
        type=int,
        default=8000,
        help="Training steps for Brush (default: 8000; use e.g. 30000 for full runs).",
    )
    parser.add_argument(
        "--brush-headless",
        action="store_true",
        help="Run Brush in the terminal only (no window). Default is to open the Brush UI.",
    )
    # ── Layer 2 flags ─────────────────────────────────────────────────────
    parser.add_argument(
        "--skip-layer2",
        action="store_true",
        help="Skip frame quality scoring / keyframe selection (Layer 2).",
    )
    parser.add_argument(
        "--blur-threshold",
        type=float,
        default=80.0,
        help="Layer 2: Laplacian variance floor (default: 80). Frames below → rejected as blurry.",
    )
    parser.add_argument(
        "--exposure-threshold",
        type=float,
        default=0.15,
        help="Layer 2: exposure score floor [0,1] (default: 0.15). Frames below → rejected.",
    )
    parser.add_argument(
        "--hamming-threshold",
        type=int,
        default=8,
        help="Layer 2: dHash Hamming distance for duplicate rejection (default: 8).",
    )
    parser.add_argument(
        "--motion-floor",
        type=float,
        default=0.03,
        help="Layer 2: motion score floor [0,1] (default: 0.03). Static frames → rejected.",
    )
    parser.add_argument(
        "--min-keep-frames",
        type=int,
        default=30,
        help="Layer 2: minimum frames to keep; thresholds relaxed if needed (default: 30).",
    )
    # ── Layer 3 flags ─────────────────────────────────────────────────────
    parser.add_argument(
        "--skip-layer3",
        action="store_true",
        help="Skip pre-COLMAP dataset audit (Layer 3).",
    )
    parser.add_argument(
        "--layer3-halt-on-critical",
        action="store_true",
        help="Layer 3: halt pipeline if critical issues are detected in the dataset audit.",
    )
    # ── Layer 4 flags ─────────────────────────────────────────────────────
    parser.add_argument(
        "--skip-layer4",
        action="store_true",
        help="Skip monocular depth map generation (Layer 4).",
    )
    parser.add_argument(
        "--depth-model",
        default="DPT_Large",
        choices=["DPT_Large", "DPT_Hybrid", "MiDaS_small", "depth_anything_v2_small"],
        help="Layer 4: depth estimation model (default: DPT_Large — matches test_dataset format).",
    )
    # ── COLMAP matcher auto-selection flags ───────────────────────────────
    parser.add_argument(
        "--no-auto-matcher",
        action="store_true",
        help="Disable auto-selection of exhaustive vs sequential matcher (use --matcher-type explicitly).",
    )
    parser.add_argument(
        "--exhaustive-threshold",
        type=int,
        default=150,
        help="Auto-matcher: use exhaustive_matcher when frame count <= this (default: 150).",
    )
    parser.add_argument(
        "--sequential-overlap",
        type=int,
        default=20,
        help="Sequential matcher overlap window (default: 20; COLMAP default is 10).",
    )
    # ── COLMAP profile ────────────────────────────────────────────────────
    parser.add_argument(
        "--colmap-profile",
        default="auto",
        choices=["normal", "video_low_texture", "video_blurry", "wide_lens_phone", "auto"],
        help=(
            "COLMAP extraction/matching profile (default: auto). "
            "auto = read Layer 3 audit and pick the best profile. "
            "normal = standard SIFT + SIMPLE_PINHOLE. "
            "video_low_texture = DSP-SIFT + affine shape + guided matching (CPU, slow). "
            "video_blurry = low peak threshold + DSP-SIFT + guided matching. "
            "wide_lens_phone = OPENCV distortion model + focal prior."
        ),
    )
    args = parser.parse_args()

    dataset_dir = (args.dataset_dir or repo_root() / "Videos_Dataset").resolve()
    if args.video is not None:
        video_path = args.video.resolve()
        selection: Literal["cli", "interactive"] = "cli"
    else:
        video_path = pick_video_interactive(dataset_dir)
        selection = "interactive"

    cfg = PipelineConfig(
        runs_root=args.runs_root.resolve() if args.runs_root else PipelineConfig().runs_root,
        max_frames=args.max_frames,
        keep_all_frames=args.keep_all_frames,
        resize_width=args.resize_width,
        resize_height=args.resize_height,
        target_fps=args.target_fps,
        copy_video_into_run=args.copy_video_beside_frames,
        matcher_type=args.matcher_type,
        interval=args.interval,
        model_type=args.model_type,
        brush_binary=args.brush_binary.resolve() if args.brush_binary else None,
        run_brush=not args.skip_brush,
        brush_total_steps=args.brush_total_steps,
        brush_headless=args.brush_headless,
        # Layer 2
        run_layer2=not args.skip_layer2,
        blur_threshold=args.blur_threshold,
        exposure_threshold=args.exposure_threshold,
        hamming_threshold=args.hamming_threshold,
        motion_floor=args.motion_floor,
        min_keep_frames=args.min_keep_frames,
        # Layer 3
        run_layer3=not args.skip_layer3,
        layer3_halt_on_critical=args.layer3_halt_on_critical,
        # Layer 4
        run_layer4=not args.skip_layer4,
        depth_model=args.depth_model,
        # COLMAP auto-matcher
        auto_select_matcher=not args.no_auto_matcher,
        exhaustive_threshold=args.exhaustive_threshold,
        sequential_overlap=args.sequential_overlap,
        # COLMAP profile
        colmap_profile=args.colmap_profile,
    )
    if not args.no_ingest_menu:
        cfg = ingest_menu_defaults(cfg)
    cfg.validate()

    try:
        out = run_pipeline(
            video_path,
            run_id=args.run_id,
            cfg=cfg,
            video_selection=selection,
        )
    except FileExistsError as e:
        print(e, file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        print(f"Pipeline failed: {e}", file=sys.stderr)
        sys.exit(1)
    print(out)


if __name__ == "__main__":
    main()
