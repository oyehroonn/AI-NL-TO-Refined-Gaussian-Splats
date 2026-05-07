# AI-NL-TO-Refined-Gaussian-Splats

> A two-pipeline system for turning the real world into editable, AI-aware
> Gaussian splats — from a video on your laptop, or from a live AR capture
> on your iPhone, with a roadmap to natural-language scene editing.

---

## What this is

Two production pipelines that share one downstream training stack:

```
┌─────────────────────────────────────────────────────────────────────┐
│                         INPUT MODALITY                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   📹 Video file (.mp4)         OR        📱 Live iPhone AR capture  │
│   upload_to_splat/                       ar_capture_to_splat/       │
│                                                                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                  COLMAP-shaped run dir under runs/                  │
│       (sparse/0/cameras.bin, images.bin, points3D.bin + frames)     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│           SHARED DOWNSTREAM (upload_to_splat layers 5/6/7)          │
│                                                                     │
│   Layer 5 ─ Brush packaging (dense init + sky masks + train)        │
│   Layer 6 ─ Post-splat quality analysis (PSNR/SSIM/floaters)        │
│   Layer 7 ─ AI splat analysis (Groq → natural-language report)      │
│                                                                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
                   📦 trained .ply Gaussian splat
                       runs/<id>/outputs/output_ply/
```

Both pipelines produce **the same artifact** — a `.ply` Gaussian splat you
can open in Brush, view in the iPhone Splattr app (planned tiers), or
hand to the upcoming AI/NL editing layer.

---

## Why it's different

Most splatting toolchains hand you raw COLMAP + a trainer and call it
done. This repo treats splatting as **a multi-stage pipeline with
quality gates, scientific analysis, and AI-driven retake advice**. Every
stage writes structured metadata that the next stage reads, and the
final layer produces a plain-language report telling you exactly *why*
your splat looks the way it does and what to film next.

| Layer | What it adds | Where the value shows up |
|---|---|---|
| **Layer 1** ingest | resize, fps cap, deterministic ffmpeg filtergraph | reproducibility |
| **Layer 2** frame quality | blur, exposure, motion, dHash dedup | COLMAP gets only sharp, diverse frames |
| **Layer 3** dataset audit | 12 issue detectors, FAIL/POOR/FAIR/GOOD readiness | fail-fast before COLMAP wastes 30 min |
| **Layer 4** depth + matcher | DPT depth maps, exhaustive vs sequential auto-matcher | better init.ply, more matches |
| **Layer 5** Brush packaging | dense init from depth, sky masks, quality presets | clean splats, no sky floaters |
| **Layer 6** quality analysis | floater detect, coverage gaps, render-vs-source eval | spatial debugging — "the back wall is bad because…" |
| **Layer 7** AI analysis | Groq Llama 3.3 → 7-section retake report | non-experts get actionable advice |

---

## Two pipelines, one output

### 🖥️  Pipeline A — `upload_to_splat/` (video on laptop)

Take an `.mp4`, get a Gaussian splat. Runs on macOS, Linux, or Windows.
Uses local COLMAP + Brush.

### 📱 Pipeline B — `ar_capture_to_splat/` (live phone capture)

Open the Splattr iOS app (in `ar_capture_to_splat/ios_app/`), scan a QR
shown on your laptop, capture a room with ARKit + LiDAR. The phone
streams the capture to your laptop, the same Layer 5/6/7 train it. With
the planned **tiered preview system**, you'll see the splat forming live
on the phone in real time (Max tier) or play it back on the phone after
training (Platinum tier).

See [`ar_capture_to_splat/README.md`](ar_capture_to_splat/README.md) for the
full AR pipeline.

---

## Quick start (Pipeline A — video → splat)

### Prerequisites

| Tool | Why | Get it |
|---|---|---|
| Python 3.10+ | orchestrator + all layers | [python.org](https://www.python.org/downloads/) |
| FFmpeg | frame extraction (Layer 1) | macOS: `brew install ffmpeg` · Win: [ffmpeg.org](https://ffmpeg.org/download.html) |
| COLMAP | SfM reconstruction (Layer 4) | macOS: `brew install colmap` · Win: [colmap.github.io](https://colmap.github.io/install.html) |
| Brush | Gaussian splat trainer + viewer | clone + `cargo build --release` (see below) |
| Rust 1.85+ | required by Brush | [rustup.rs](https://rustup.rs/) |
| PyTorch (+ MPS / CUDA) | DPT depth (Layer 4) | `pip install torch torchvision` |
| OpenCV + NumPy | every layer | `pip install opencv-python numpy` |

> **Windows users:** see the **[Windows install notes](#windows-install-notes)**
> section below for the full step-by-step.

### Setup (one-time, macOS)

```bash
# 1. Clone this repo
git clone <your-fork-url> AI-NL-TO-Refined-Gaussian-Splats
cd AI-NL-TO-Refined-Gaussian-Splats

# 2. Install Python deps
pip install torch torchvision opencv-python numpy

# 3. Install COLMAP + FFmpeg
brew install colmap ffmpeg

# 4. Build Brush from source
git clone https://github.com/ArthurBrussee/brush.git brush
cd brush && cargo build --release && cd ..

# 5. (Optional) Set up the AI analysis layer
echo "GROQ_API_KEY=your-key-here" > .env
echo "GROQ_MODEL=llama-3.3-70b-versatile" >> .env
```

### Run a video → splat job

```bash
# Interactive picker — lists files in Videos_Dataset/
python3 -m pipeline.run_pipeline

# Or explicit file
python3 -m pipeline.run_pipeline --video Videos_Dataset/myroom.mp4
```

The orchestrator walks you through ingest options, runs every layer, and
prints a colored progress report. **Each run lands in `runs/<run_id>/`**
with the alphabetic naming (A0, A1, A2, …, A10, B0, B1, …, Z10, AA0, …).

### Run output

```
runs/A2__myroom/
  input/input.mp4                          ← canonical source copy
  images/, source/                         ← Layer 1 frames
  images_rejected/                         ← Layer 2 filtered out
  dpt/                                     ← Layer 4 depth maps
  distorted/, sparse/0/                    ← Layer 4 COLMAP output
  init.ply, masks/                         ← Layer 5 dense init + sky masks
  outputs/output_ply/export_*.ply          ← TRAINED SPLAT (Layer 5)
  layer6_heatmaps/*.png                    ← Layer 6 per-view error
  layer7_report.md                         ← Layer 7 NL retake advice
  metadata/run_metadata.json               ← full provenance
```

### Open the trained splat

```bash
brush/target/release/brush_app runs/A2__myroom/outputs/output_ply/export_06000.ply
```

---

## Quick start (Pipeline B — iPhone → splat)

```bash
# 1. (one-time) Install + sign the iOS app per ar_capture_to_splat/ios_app/IOS_SETUP.md
# 2. Start the laptop session server — shows a QR code
python3 -m ar_capture_to_splat.scripts.session_layer.run_layer0 --scene-type room

# 3. Scan the QR with the Splattr app on your iPhone (LiDAR-capable Pro recommended)
# 4. Pick a scene type → tutorial → capture → upload
# 5. After upload, AR-Layer 4 (pose bridge) converts the capture to a Brush-shaped
#    run dir; the same Layer 5/6/7 train it
```

See [`ar_capture_to_splat/README.md`](ar_capture_to_splat/README.md) for full
details, the **tier system** (Gold / Platinum / Max / On-Mobile), and the
ARKit data-capture spec.

---

## Per-layer documentation

- **`upload_to_splat/`** — every layer's source + per-layer JSON shape
- **`ar_capture_to_splat/CAPTURE_PROTOCOL.md`** — iOS→laptop wire contract
- **`ar_capture_to_splat/IMPLEMENTATION_PLAN.md`** — Layer 4/5 + tier roadmap
- **`ar_capture_to_splat/ios_app/IOS_SETUP.md`** — Xcode signing + run-on-device
- **memory/system_progress.md** — historical session notes (auto-memory)

---

## Windows install notes

Every layer of `upload_to_splat/` is pure Python + cross-platform deps,
so the pipeline runs on Windows once you have the four binaries below.

### 1. Python

Install Python 3.10+ from [python.org](https://www.python.org/downloads/),
ensuring **"Add Python to PATH"** is checked.

```powershell
py -3.11 --version
```

### 2. FFmpeg

Download a pre-built FFmpeg from <https://www.gyan.dev/ffmpeg/builds/> →
extract → add `<extracted>\bin` to your **System PATH**. Verify:

```powershell
ffmpeg -version
```

### 3. COLMAP

Download the **CUDA-enabled** Windows release (recommended) from the
[COLMAP releases page](https://github.com/colmap/colmap/releases). Pick
`COLMAP-x.y-windows-cuda.zip` for NVIDIA GPUs or
`COLMAP-x.y-windows-no-cuda.zip` for CPU-only. Extract → add the COLMAP
folder to your **System PATH**. Verify:

```powershell
colmap --version
```

### 4. Rust + Brush

```powershell
# Install rustup (or via winget)
winget install Rustlang.Rustup
# Restart your shell, then:
rustup default stable
git clone https://github.com/ArthurBrussee/brush.git brush
cd brush
cargo build --release
cd ..
```

The binary lands at `brush\target\release\brush_app.exe`. The Python
orchestrator auto-detects this on Windows.

### 5. Python deps

```powershell
# NVIDIA GPU
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
# CPU-only
pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu

pip install opencv-python numpy
```

### 6. Run

```powershell
python -m pipeline.run_pipeline --video Videos_Dataset\myroom.mp4
```

Identical run-folder structure and output as macOS / Linux.

---

## Future layers (coming soon)

The current 7-layer pipeline ends at "trained splat + AI retake advice."
The next big leap is **AI-native splat editing** via natural language —
an entire family of upcoming layers that will turn this from a capture
tool into a creative platform.

### 🌌 Layer 8 — NL Scene Editor (planned)

Type `add a vintage red leather chair next to the window` and watch the
splat update. Powered by:

- **A scene-graph extractor** that segments the splat into named objects
  ("window", "wall", "floor", "chair-1") using grounded SAM + 3D
  classification cues from sceneReconstruction.
- **A 3D asset generator** chained to **image-gen** + **video-gen** APIs
  ([Nano Banana](https://nanobanana.ai), [Seedance](https://seedance.video),
  Anthropic Claude Vision, OpenAI DALL·E) that turns a text prompt + the
  scene's lighting into a multi-view image set.
- **A novel-view-to-splat distiller** that fits a small Gaussian
  patch from those generated views and merges it into the parent splat
  at the requested location.

Result: photorealistic objects added, removed, or restyled inside an
existing splat with one prompt.

### 🎬 Layer 9 — Time + Motion (planned)

Take a static splat and **animate it**. Prompts like `make the curtain
sway in a gentle breeze`, `play the fireplace burning`, or `show this
room at sunset`:

- A **Seedance-class video model** generates the appearance change as a
  short video conditioned on the current splat's renders.
- A per-frame **delta-splat trainer** fits a 4D field over the static
  base, learning Gaussian deltas keyed to time. Output is a
  time-varying splat the user can scrub.

### 🪄 Layer 10 — Style + World Transfer (planned)

`make this whole room cyberpunk`, `repaint the walls in a Wes Anderson
palette`, `set the scene in a forest`. Image-to-image style models
applied per-Gaussian, with view-consistency enforced by a small
contrastive fine-tune step.

### 🎙️ Layer 11 — Voice & VR Editing (planned)

Walk into your splat in VR, point at a chair, say "swap this for a
mid-century modern one," and see the change in seconds. Built on Layer
8 + speech-to-prompt + a Vision Pro / Quest 3 viewer.

### 🤖 Layer 12 — Agent Mode (planned)

`Claude, restage this room as a luxury Airbnb listing`. A multi-step
agent decides the edits, runs the layers, evaluates the result with
Layer 6 metrics, and iterates until the scene meets the brief.

### Other directions on the roadmap

- **Splat compression** — neural-codec post-process so a 100 MB splat
  becomes 5 MB without visible quality loss.
- **Streaming splats** — progressive LOD over WebSocket so massive
  outdoor scenes load instantly on phone.
- **Multi-capture fusion** — automatically merge multiple AR captures of
  the same room over days into one continuously-improving splat.
- **AR persistence cloud** — share a splat with friends; they see it
  positioned exactly where you placed it via shared ARWorldMap.
- **Robotics export** — splats double as occupancy fields; export
  directly to ROS / Gazebo / NVIDIA Isaac for sim-to-real.
- **Dataset-as-code** — `.splatproj` file format that bundles capture +
  policy + edits as a versionable artifact.

---

## Contributing

This repo evolves rapidly. The two best places to start:

1. Read [`ar_capture_to_splat/IMPLEMENTATION_PLAN.md`](ar_capture_to_splat/IMPLEMENTATION_PLAN.md)
   for the live engineering plan.
2. Pick an open layer (currently AR-Layer 4 + 5 + tier C) and ship it.

---

## Acknowledgements

- [COLMAP](https://colmap.github.io/) — SfM backbone
- [Brush](https://github.com/ArthurBrussee/brush) — Rust/WGPU Gaussian
  splat trainer that the laptop pipeline drives
- [MiDaS / DPT](https://github.com/isl-org/MiDaS) — monocular depth (Layer 4)
- [Groq](https://groq.com/) — fast inference for the Layer 7 NL report
- ARKit + sceneReconstruction (Apple) — phone-side capture
