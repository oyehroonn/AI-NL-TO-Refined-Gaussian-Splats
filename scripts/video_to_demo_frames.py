#!/usr/bin/env python3
"""
Extract frames from a video into demo_dir/images/.

Requires ffmpeg and ffprobe on PATH.

- If the video has more than --max-frames (default 250), frames are subsampled
  uniformly in time to at most that many frames, and a notice is printed.
- If it already has <= max frames, every frame is exported (native timing).
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


def _run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=True,
        capture_output=True,
        text=True,
    )


def probe_video(video_path: Path) -> tuple[float, float | None, int | None]:
    """
    Returns (duration_seconds, avg_frame_rate or None, nb_read_frames or None).
    nb_read_frames may be missing for some codecs/containers.
    """
    out = _run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-count_frames",
            "-show_entries",
            "stream=duration,avg_frame_rate,r_frame_rate,nb_read_frames",
            "-of",
            "json",
            str(video_path),
        ]
    )
    data = json.loads(out.stdout)
    streams = data.get("streams") or []
    if not streams:
        raise RuntimeError("No video stream found in file.")
    s = streams[0]
    dur_raw = s.get("duration")
    duration = float(dur_raw) if dur_raw not in (None, "N/A") else 0.0

    def parse_rate(r: str | None) -> float | None:
        if not r or r == "N/A":
            return None
        if "/" in r:
            a, b = r.split("/", 1)
            b = float(b)
            if b == 0:
                return None
            return float(a) / b
        return float(r)

    fps = parse_rate(s.get("avg_frame_rate")) or parse_rate(s.get("r_frame_rate"))

    nb = s.get("nb_read_frames")
    if nb in (None, "N/A"):
        nb_frames = None
    else:
        nb_frames = int(nb)

    if duration <= 0:
        d2 = _run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(video_path),
            ]
        ).stdout.strip()
        if d2:
            duration = max(float(d2), 1e-3)

    return duration, fps, nb_frames


def estimate_frame_count(duration: float, fps: float | None, nb_read_frames: int | None) -> int:
    if nb_read_frames is not None and nb_read_frames > 0:
        return nb_read_frames
    if fps and duration > 0:
        return max(1, int(round(duration * fps)))
    raise RuntimeError(
        "Could not determine frame count (try a different container/codec or re-encode the video)."
    )


def next_demo_directory(demos_root: Path) -> Path:
    demos_root.mkdir(parents=True, exist_ok=True)
    best = 0
    for p in demos_root.iterdir():
        if not p.is_dir() or not p.name.startswith("demo_"):
            continue
        suffix = p.name[len("demo_") :]
        if suffix.isdigit():
            best = max(best, int(suffix))
    return demos_root / f"demo_{best + 1}"


def extract_video_to_images(
    video_path: Path,
    demo_dir: Path,
    *,
    max_frames: int = 250,
    image_pattern: str = "frame_%06d.jpg",
    copy_source_video: bool = True,
) -> dict:
    """
    Create demo_dir/images/ and write frames. Optionally copy the source video into demo_dir.

    Returns a small stats dict for logging.
    """
    video_path = video_path.resolve()
    if not video_path.is_file():
        raise FileNotFoundError(video_path)

    images_dir = demo_dir / "images"
    if images_dir.exists():
        shutil.rmtree(images_dir)
    images_dir.mkdir(parents=True, exist_ok=True)

    duration, fps, nb_probe = probe_video(video_path)
    est_frames = estimate_frame_count(duration, fps, nb_probe)

    stats: dict = {
        "video": str(video_path),
        "demo_dir": str(demo_dir),
        "duration_sec": duration,
        "probed_nb_read_frames": nb_probe,
        "estimated_input_frames": est_frames,
        "max_frames": max_frames,
        "subsampled": False,
    }

    out_template = str(images_dir / image_pattern)

    if est_frames <= max_frames:
        print(
            f"Video has about {est_frames} frame(s) (<= {max_frames}); exporting all frames without temporal subsampling."
        )
        cmd = [
            "ffmpeg",
            "-y",
            "-i",
            str(video_path),
            "-vsync",
            "0",
            "-qscale:v",
            "2",
            out_template,
        ]
    else:
        stats["subsampled"] = True
        target_fps = max_frames / max(duration, 1e-3)
        print(
            f"\n*** NOTICE: Video has about {est_frames} frames (> {max_frames}). ***\n"
            f"Subsampling uniformly in time to ~{max_frames} frames "
            f"(fps filter ≈ {target_fps:.4f} over {duration:.2f}s).\n"
        )
        vf = f"fps={target_fps}"
        cmd = [
            "ffmpeg",
            "-y",
            "-i",
            str(video_path),
            "-vf",
            vf,
            "-qscale:v",
            "2",
            out_template,
        ]

    subprocess.run(cmd, check=True)

    written = len([f for f in images_dir.iterdir() if f.is_file()])
    stats["frames_written"] = written

    if copy_source_video:
        dest_vid = demo_dir / video_path.name
        shutil.copy2(video_path, dest_vid)
        stats["video_copy"] = str(dest_vid)

    print(f"Wrote {written} frame(s) to {images_dir}")
    return stats


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", type=Path, required=True, help="Input video file.")
    parser.add_argument(
        "--demo-dir",
        type=Path,
        required=True,
        help="Output demo folder (images/ created inside).",
    )
    parser.add_argument(
        "--max-frames",
        type=int,
        default=250,
        help="Maximum number of frames to keep (default: 250).",
    )
    parser.add_argument(
        "--no-copy-video",
        action="store_true",
        help="Do not copy the source video into the demo folder.",
    )
    args = parser.parse_args()

    for bin_name in ("ffmpeg", "ffprobe"):
        if shutil.which(bin_name) is None:
            print(f"Error: '{bin_name}' not found on PATH. Install ffmpeg.", file=sys.stderr)
            sys.exit(1)

    args.demo_dir.mkdir(parents=True, exist_ok=True)
    extract_video_to_images(
        args.video,
        args.demo_dir,
        max_frames=args.max_frames,
        copy_source_video=not args.no_copy_video,
    )


if __name__ == "__main__":
    main()
