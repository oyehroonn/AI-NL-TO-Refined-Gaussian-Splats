# AI NL to Refined Gaussian Splats

## Baseline pipeline (Layer 0)

From the repository root, run the orchestrator so each job writes under `runs/<run_id>/` with logs, metadata, and stable subpaths.

**Interactive pick** (no path typing): omits `--video` and lists files in `Videos_Dataset/`; enter a number to continue:

```bash
python3 -m pipeline.run_pipeline
```

**Explicit path**:

```bash
python3 -m pipeline.run_pipeline --video Videos_Dataset/your_clip.mp4
```

**Another folder for the picker**: `--dataset-dir /path/to/clips` (still omit `--video` to get the menu).

Layout per run:

| Path | Purpose |
|------|---------|
| `input/input.mp4` | Canonical copy of the source video |
| `images/` then `source/` | Extracted frames (COLMAP renames `images` → `source`) |
| `distorted/`, `sparse/0/` | COLMAP database and model |
| `colmap_run.log` | COLMAP stage log |
| `metadata/run_metadata.json` | Run config, stage timings, resolved paths |
| `logs/pipeline.log` | Orchestrator log |
| `outputs/splat/` | Place for exported `.ply` (Brush or manual) |

After COLMAP, the pipeline **launches the Brush app with the UI by default** when `brush/target/release/brush_app` exists (dataset = the run folder: `images/` + `sparse/0/`). You can watch training in the window; exports still go to `runs/<id>/outputs/splat/`. Flags: `--brush-headless` (terminal-only, no window), `--skip-brush`, `--brush-binary PATH`, `--brush-total-steps N` (default 8000). If `brush_app` is missing, the Brush stage is skipped with a log message and COLMAP outputs are kept. Lower-level scripts remain in `scripts/`.

## Layer 1 ingest options (deterministic preprocessing)

When you run `python3 -m pipeline.run_pipeline`, it prompts you for ingest options with recommended defaults:

- **Resize**: none (default) or common widths (1280/1920) or custom.
- **Frame-rate reduction**: cap to `--max-frames` (default 250), keep all frames, or target FPS.

These options are executed as a single FFmpeg **filtergraph** (e.g. `scale=...,fps=...`) and written into the run metadata (`metadata/run_metadata.json`) and extract-stage stats.

To skip the menu and use CLI defaults/flags, pass `--no-ingest-menu`.

## COLMAP (local copy, not in Git)

This repository does not include the COLMAP sources on GitHub. If you need a full tree next to the project (for example `colmap-4.0.3/`), obtain it yourself using one of the options below.

### Option A: Clone a release tag (matches a `colmap-x.y.z` folder)

From the repository root:

```bash
git clone --depth 1 --branch 4.0.3 https://github.com/colmap/colmap.git colmap-4.0.3
```

Replace `4.0.3` with the tag you want from [COLMAP releases](https://github.com/colmap/colmap/releases).

### Option B: Download a source archive

1. Open [https://github.com/colmap/colmap/releases](https://github.com/colmap/colmap/releases).
2. Under **Assets**, download the **Source code** archive for the version you need (for example `Source code (zip)`).
3. Extract it in this repository’s root and rename the folder to something like `colmap-4.0.3` if you prefer a consistent path.

### Option C: Install a binary build (no local source tree)

You do not need a `colmap-*` folder in this repo if you only need the `colmap` command:

- **Conda**: [https://anaconda.org/conda-forge/colmap](https://anaconda.org/conda-forge/colmap) — e.g. `conda install -c conda-forge colmap`
- **Homebrew (macOS)**: `brew install colmap`
- **Docker**: [https://hub.docker.com/r/colmap/colmap](https://hub.docker.com/r/colmap/colmap)

Official build-from-source and install details: [https://colmap.github.io/install.html](https://colmap.github.io/install.html).

## Brush (local copy, not in Git)

[Brush](https://github.com/ArthurBrussee/brush) is a Gaussian-splatting training and viewing stack (WebGPU, Rust). This repository does not include its sources on GitHub. To place a copy next to this project as `brush/`, use one of the following.

### Install (source tree at `./brush`)

1. Install **Rust 1.85 or newer** ([https://rustup.rs/](https://rustup.rs/)).
2. From this repository’s root, clone Brush:

   **Latest `main`:**

   ```bash
   git clone https://github.com/ArthurBrussee/brush.git brush
   ```

   **Pinned release (example `v0.3.0`):**

   ```bash
   git clone --depth 1 --branch v0.3.0 https://github.com/ArthurBrussee/brush.git brush
   ```

   Other tags are listed under [https://github.com/ArthurBrussee/brush/tags](https://github.com/ArthurBrussee/brush/tags).

3. Build and run the app from the Brush root (`brush/`):

   ```bash
   cd brush
   cargo run --release
   ```

   Command-line options (train paths, viewer flags, etc.) are shown with:

   ```bash
   cargo run --release -- --help
   ```

   The release binary ends up under `brush/target/release/` (for example `brush_app` for the default desktop target).

### Using Brush (short overview)

- **Training**: Feed **posed** images—typically a **COLMAP** reconstruction folder or a **Nerfstudio**-style dataset. You can inspect and compare views while training.
- **Viewer**: Opens **`.ply`** / **`.compressed.ply`** splats; supports **`.zip`** of splats for playback-style use. Web demo and details: [Brush README](https://github.com/ArthurBrussee/brush/blob/main/README.md) and [https://arthurbrussee.github.io/brush-demo](https://arthurbrussee.github.io/brush-demo).
- **Optional Rerun logging** (extra training visualizations): install the Rerun CLI (`cargo install rerun-cli`) and follow [https://rerun.io/docs/getting-started/installing-viewer](https://rerun.io/docs/getting-started/installing-viewer). Upstream notes opening `./brush_blueprint.rbl` in the viewer for a preset layout.

Full build options (web, Android, tests) are documented in the upstream repository: [https://github.com/ArthurBrussee/brush](https://github.com/ArthurBrussee/brush).
