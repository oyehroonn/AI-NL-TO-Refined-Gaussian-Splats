# AI NL to Refined Gaussian Splats

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

   For a quick CLI overview without starting the full UI workflow you care about, see `cargo run --release -- --help` from that directory (equivalent to running the `brush` binary with `--help` once built).

### Using Brush (short overview)

- **Training**: Feed **posed** images—typically a **COLMAP** reconstruction folder or a **Nerfstudio**-style dataset. You can inspect and compare views while training.
- **Viewer**: Opens **`.ply`** / **`.compressed.ply`** splats; supports **`.zip`** of splats for playback-style use. Web demo and details: [Brush README](https://github.com/ArthurBrussee/brush/blob/main/README.md) and [https://arthurbrussee.github.io/brush-demo](https://arthurbrussee.github.io/brush-demo).
- **Optional Rerun logging** (extra training visualizations): install the Rerun CLI (`cargo install rerun-cli`) and follow [https://rerun.io/docs/getting-started/installing-viewer](https://rerun.io/docs/getting-started/installing-viewer). Upstream notes opening `./brush_blueprint.rbl` in the viewer for a preset layout.

Full build options (web, Android, tests) are documented in the upstream repository: [https://github.com/ArthurBrussee/brush](https://github.com/ArthurBrussee/brush).
