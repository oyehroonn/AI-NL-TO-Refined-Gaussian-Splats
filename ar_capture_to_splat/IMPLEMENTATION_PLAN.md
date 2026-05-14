# AR-Capture-to-Splat — Implementation Plan

This document is the durable reference for everything that turns a phone-held
ARKit capture into a viewable Gaussian splat. It covers the remaining backend
layer (AR-Layer 4 + 5) and the four user-facing **preview tiers** that decide
*how* and *where* the splat is rendered to the user during/after capture.

Read this first when picking up implementation work on the AR pipeline.

---

## TL;DR — current state

| Component | Status |
|---|---|
| AR-Layer 0 — session, QR handoff, multipart server | ✅ shipped |
| AR-Layer 1 — capture-policy + tutorial (8 modes) | ✅ shipped |
| AR-Layer 2 — ARSession + per-frame data + coverage/loop | ✅ shipped |
| AR-Layer 2.5 — live sceneReconstruction mesh overlay | ✅ shipped |
| AR-Layer 3 — capture-package builder (manifest + sidecars + upload) | ✅ shipped |
| **AR-Layer 4 — pose bridge (ARKit poses → COLMAP)** | 🟡 in this doc, next to ship |
| **AR-Layer 5 — LiDAR depth → DPT-equivalent** | 🟡 in this doc, follows L4 |
| **Tier C / "Gold" — textured mesh in viewfinder** | 🟡 in this doc, free tier |
| **Tier D / "Platinum" — post-hoc on-device splat playback** | 🟡 in this doc, paid |
| **Tier B / "Max" — hybrid live training (laptop GPU)** | 🟡 in this doc, top tier |
| **Tier A / "On-Mobile" — true on-device 3DGS training** | 🔵 deferred, plan saved |

---

## Section 1 — AR-Layer 4: Pose Bridge (Python)

### Why it exists

Layer 3 lands a typed manifest + raw frames + ARKit poses + sceneReconstruction
mesh + worldmap in `ar_runs/<id>/capture/`. The existing splat pipeline
(`upload_to_splat/`) expects a **COLMAP-shaped run dir** — `sparse/0/` with
`cameras.bin`, `images.bin`, `points3D.bin`, and `images/` of frames. Layer 4
is the adapter that turns one shape into the other so we can reuse every
downstream layer (5/6/7) without modification.

### Where it lives

```
ar_capture_to_splat/scripts/pose_bridge_layer/
  __init__.py
  colmap_writers.py       — write cameras.bin, images.bin, points3D.bin
  ar_run_reader.py        — load + validate manifest.json
  feature_points_loader.py— decode capture/feature_points/*.bin → points3D
  run_layer4.py           — public run_layer4() + CLI
  AR_LAYER4_README.md     — short usage doc
```

### Inputs

```
ar_runs/<id>/capture/
  manifest.json
  frames/frame_<N>.jpg                 (accepted, HR or preview)
  depth/frame_<N>.bin                  (LiDAR — Layer 5 will use these)
  feature_points/frame_<N>.bin         (sparse cloud + persistent IDs)
  world_map.arworldmap                 (optional, future use)
  scene_mesh.obj                       (optional, future Layer 5b)
  rejected_frames.json                 (audit only)
```

### Outputs (COLMAP-shaped run dir, identical to `runs/<id>/`)

```
runs/<run_id>__<scene_name>/
  input/
  images/                              — copied from capture/frames/
  source/                              — same images, COLMAP rename target
  sparse/0/
    cameras.bin                        — one camera per unique intrinsics row
    images.bin                         — one image record per accepted frame,
                                         with ARKit transform → COLMAP pose
    points3D.bin                       — sparse cloud reduced from
                                         feature_points/*.bin, joined by ID
  metadata/
    run_metadata.json                  — paths, ARKit→COLMAP timing, source = "ar"
    layer4_pose_bridge.json            — per-frame pose-quality, residuals,
                                         track-length stats
  logs/layer4.log
```

### Algorithm

1. **Validate manifest** — schema_version, accepted frames count ≥ 10,
   per-frame intrinsics + transform present + finite.
2. **Camera dedup** — group accepted frames by their 3×3 intrinsics; one
   `Camera` record per unique row. Model: `OPENCV` with k1=k2=p1=p2=0
   (ARKit returns rectified intrinsics already). Width/height come from each
   frame's `image_width/image_height`.
3. **Pose conversion** — ARKit camera convention: world frame (right-handed,
   +Y up, -Z forward), `camera_transform_world` is **camera→world**. COLMAP
   wants **world→camera** = `inv(camera_transform_world)`. Decompose into
   quaternion (qw, qx, qy, qz) and translation (tx, ty, tz) for `images.bin`.
4. **Feature-point fusion** — ARKit's `rawFeaturePoints` carries persistent
   `UInt64` identifiers across frames. Layer 4 reads every accepted frame's
   `feature_points/*.bin`, builds a multimap `point_id → [(frame, x_2d_or_unknown)]`,
   and emits a `points3D.bin` record per ID that's seen in ≥ 2 frames. The 3D
   xyz comes from the *median* of that point's 3D positions across frames
   (ARKit gives 3D world positions per frame, so we average them, not
   triangulate). Track 2D residuals are unknown → store the median-projected
   pixel as the 2D obs.
5. **Image copy** — accepted frames' JPEGs copied/symlinked into `images/`
   with COLMAP-friendly stable names (`frame_000074.jpg`, etc.). The
   pipeline rename to `source/` happens later (existing convention).
6. **Run-metadata write** — preserves provenance: `source = "ar"`,
   `ar_run_id`, `ar_session_id`, `n_frames_in`, `n_frames_used`, `n_points_3d`,
   `mean_track_length`, `pose_conversion_seconds`.
7. **Hand off** — call `pipeline.run_pipeline.run_pipeline(...)` with
   `--skip-extract --skip-layer2 --skip-layer3 --skip-layer4 --skip-colmap`
   so the existing trainer (Layer 5/6/7 in `upload_to_splat/`) picks up
   the synthesized COLMAP dir directly. *(Adds those skip flags to the
   orchestrator if not present yet — see "open work" below.)*

### Knowns and edge cases

- **ARKit poses are noisier than COLMAP** by ~3-10 cm typically. We accept
  this; the splat trainer handles small pose noise. If the splat looks
  "smeared," we can add a Layer 4b that does a few BA refinement steps in
  COLMAP using the ARKit poses as priors.
- **Persistent IDs reset across sessions** — only useful within one capture.
  Layer 4 is single-run only.
- **Intrinsics may vary per-frame** when HR captures use a different
  format than preview captures. We dedup by exact-match; a typical run
  produces 1-2 distinct intrinsics rows.
- **Rejected frames are ignored** — they don't have JPEGs on disk, so
  COLMAP can't use them. Their metadata stays in the manifest for audit.

### Public API

```python
def run_layer4(
    ar_run_dir: Path,
    *,
    runs_root: Path | None = None,            # default <repo>/runs/
    run_id_prefix: str | None = None,         # default A-Z naming from pipeline.run_pipeline.default_run_id
    copy_mode: Literal["copy", "symlink"] = "symlink",
    verbose: bool = True,
) -> dict:
    """
    Convert ar_runs/<id>/capture/ → runs/<new_id>/ with COLMAP layout.
    Returns a summary dict mirroring metadata/layer4_pose_bridge.json.
    """
```

### CLI

```bash
python3 -m ar_capture_to_splat.scripts.pose_bridge_layer.run_layer4 \
  --ar-run-dir ar_runs/run6__MyDrawing \
  --runs-root runs/ \
  [--copy]                  # default symlink
```

### Open work (small) needed in `pipeline/run_pipeline.py`

Add CLI flags `--skip-extract`, `--skip-colmap` (if not already there) so the
orchestrator can skip the upfront stages when handed a pre-built dataset by
Layer 4. Layer 4 then invokes:

```bash
python3 -m pipeline.run_pipeline --dataset-dir runs/<new_id> --skip-extract --skip-colmap
```

---

## Section 2 — AR-Layer 5: LiDAR depth → DPT-equivalent (Python)

### Why it exists

`upload_to_splat/brush_packaging_layer/dense_init.py` currently builds
`init.ply` from monocular DPT depth maps. AR captures already ship **real
metric LiDAR depth** in `capture/depth/*.bin` plus per-pixel confidence in
`capture/depth_confidence/*.bin`. Layer 5 converts those into the same
file shape `dense_init.py` reads from `dpt/`, so init.ply is built from
real depth instead of monocular estimates — much higher quality init.

### Where it lives

```
ar_capture_to_splat/scripts/lidar_depth_layer/
  __init__.py
  lidar_to_dpt_format.py    — LiDAR float32 + confidence → grayscale PNG
                              that dense_init.py expects
  run_layer5.py             — public entry + CLI
```

### Algorithm

1. Read each `capture/depth/frame_<N>.bin` (16-byte header + float32 row-major).
2. Read paired `capture/depth_confidence/frame_<N>.bin` (uint8 0/1/2).
3. Mask out confidence < 1 (low-confidence pixels become 0 in output).
4. Invert depth (DPT convention: 255 = closest), normalize per-frame to uint8.
5. Resize to match the matching JPEG's resolution (LiDAR depth is 256×192;
   we upsample with bilinear, matching DPT's behavior).
6. Write to `runs/<id>/dpt/frame_<N>.png` (existing convention).
7. Layer 5 (in `upload_to_splat/brush_packaging_layer/run_layer5.py`) finds
   `dpt/` automatically and the dense init kicks in.

### Public API

```python
def run_layer5(run_dir: Path, ar_run_dir: Path, *, verbose: bool = True) -> dict:
    """ar_run_dir/capture/depth/ + depth_confidence/ → run_dir/dpt/."""
```

---

## Section 3 — The Tier System (live preview during/after capture)

The tier system is purely about **what the user sees on the phone** and
*when*. Capture, upload, and laptop training behavior are identical across
all tiers — only the visualization differs.

| Tier | Internal name | Free? | What user sees during capture | Where the splat trains |
|---|---|---|---|---|
| Gold | `tier_gold_textured_mesh` | ✅ free | Live LiDAR mesh in viewfinder, RGB-projected — fills in as you scan | Laptop (post-capture) |
| Platinum | `tier_platinum_postcapture_player` | 💲 paid | Live mesh during capture (same as Gold) + a "View Splat" screen on phone after laptop trains | Laptop |
| Max | `tier_max_hybrid_live` | 💲💲 top | Real splat being trained on laptop streamed back to phone in real time as overlay | Laptop (real-time stream) |
| On-Mobile | `tier_onmobile_native` | 🔵 coming soon | Real splat training **on the phone** — Brush-style filling in | Phone |

### Tier UX surface

JoinView gets a new **"Quality"** card right under the cadence card:

```
QUALITY
[ Gold • Free        ] active
[ Platinum • $X      ]
[ Max • $XX          ]
[ On-Mobile • soon   ] disabled
```

Each tier:
- Shows headline + 1-line description + one "benefit pill" (Free / Pro / Studio / Beta)
- Selecting it persists into `CaptureSettings.tier()` (UserDefaults)
- The tier affects: which preview engine is active in `CaptureView`, which
  splat-playback screen runs after `DoneView`, and whether a real-time
  WebSocket connection is opened.

### Tier C — Gold (free) — Textured mesh in viewfinder

**What you see**: As you sweep the room, the LiDAR-derived mesh appears in
the live AR view. Instead of flat classification colors (current Layer 2.5
behavior), each face is **textured with the live camera image** projected
onto it via planar projection from the camera transform. The result is a
3D model that "fills in" with the actual appearance of the room as you walk
around — the cheap visual approximation of the "filling-in" effect.

**Not a splat.** This is a textured polygon mesh. The user gets the
*feeling* of a 3D scene forming live; the actual splat trains on the
laptop after upload.

**Files**:

```
ios_app/Splattr/Capture/
  TexturedMeshRenderer.swift      — replaces flat classification color with
                                    a per-anchor SCNMaterial whose diffuse
                                    is a snapshot of the camera image at
                                    anchor-add time, projected via SCNMaterial
                                    contentsTransform from the camera
                                    transform at that moment.
ios_app/Splattr/AppState/
  CaptureSettings.swift           — add `tier()` / `setTier()` accessors
ios_app/Splattr/UI/
  TierSelector.swift              — new selector card in JoinView
```

**Implementation**:

1. New `TextureSnapshot` actor: holds at most ~32 recent (cgImage, cameraTransform)
   pairs. ARSCNView callback `renderer(_:willRenderScene:atTime:)` captures
   `arSession.currentFrame.capturedImage` to a `CIImage`, downsizes to 512×384,
   converts to UIImage, stores it.
2. When a new ARMeshAnchor arrives in `MeshLiveRenderer.didAdd`:
   - Find the closest TextureSnapshot in time
   - Set the SCNMaterial's diffuse to that UIImage
   - Set `contentsTransform` so the texture maps onto the mesh via planar
     projection from the snapshot's camera pose
3. On `didUpdate`, optionally re-grab a fresh snapshot if the mesh anchor
   has grown ≥ 25 % in vertex count (avoids constant re-projection).
4. Tier toggles between Gold (textured) and Layer 2.5 base (flat-colored)
   live without restarting the session.

**Effort**: 2-3 days.

### Tier D — Platinum (paid) — Post-capture on-phone splat player

**What you see**: Capture experience is the same as Gold (live textured
mesh). After upload + laptop training finishes, the phone receives a
push from the laptop session ("Your splat is ready"), opens a new
**Splat Player** screen, and lets the user orbit the trained Gaussian
splat as a real 3D model in AR space. The user can pinch/scale, rotate,
and even "place" the splat in their room via plane-anchor.

**Files**:

```
ios_app/Splattr/SplatPlayback/        — new module
  PlyDecoder.swift                    — parse Brush-format binary PLY
                                        (float x,y,z + float r,g,b — same
                                        format upload_to_splat exports)
  GaussianSplatRenderer.swift         — Metal compute shader rendering
                                        (port of Brush's WGSL kernels via
                                        the existing community Metal port)
  SplatScene.swift                    — SwiftUI wrapper around an MTKView
                                        with the renderer
  SplatPlayerView.swift               — full-screen viewer w/ AR placement
ios_app/Splattr/Networking/
  SplatDownloadClient.swift           — GET /splat/<run_id>.ply from laptop
                                        + progress
scripts/session_layer/
  splat_serve.py                      — new endpoint: GET /splat/<run_id>
                                        returns the latest output_ply/
                                        export_*.ply for that run
```

**Implementation order**:

1. Laptop side: `splat_serve.py` extends the existing session server with
   a `/splat/<run_id>` GET that returns the freshest PLY in
   `runs/<id>/outputs/output_ply/`. Reuses the same session security (LAN
   trust + session_id).
2. Phone side: Metal shader port. The community already has a
   `metal-splatting` open-source library that mirrors Brush's WGSL
   rasterizer. We embed it as a sub-folder under `SplatPlayback/`
   (~1500 LOC of MSL + Swift glue).
3. UI: `SplatPlayerView` is a sheet that presents on `DoneView` if Tier ≥
   Platinum. A "Place in your room" button enters AR mode using
   ARWorldTrackingConfiguration + a plane anchor; the Metal renderer
   composites onto the camera feed via SceneKit's external-view bridge.

**Effort**: 5-7 days.

### Tier B — Max — Hybrid live training (laptop GPU streams to phone)

**What you see**: Phone keeps capturing, but every accepted frame is also
streamed to the laptop in real time over a persistent WebSocket. The
laptop runs Brush continuously, training a splat that grows in quality
every few seconds. Every ~3 seconds the laptop renders a "novel view"
from the current camera pose (or a future-predicted pose) and ships back
a 1024×768 RGB frame. The phone composites that view over the live
camera feed at low alpha — the "Brush in your viewfinder" feeling, but
the GPU work happens on the Mac.

**Files**:

```
ios_app/Splattr/Networking/
  LiveStreamUploader.swift          — opens WS to laptop, sends each
                                      accepted frame as it lands
  RemoteRenderClient.swift          — receives MJPEG-style novel-view
                                      stream from laptop, decodes to
                                      CIImage on a background thread
ios_app/Splattr/UI/
  HybridLiveOverlay.swift           — composites RemoteRenderClient
                                      output over the camera passthrough
                                      with alpha animation
scripts/session_layer/
  live_stream_server.py             — WS server; spawns a Brush subprocess
                                      that consumes frames on a unix
                                      pipe, captures its eval renders,
                                      restreams them back to phone
upload_to_splat/brush_packaging_layer/
  brush_streaming_adapter.py        — new mode for brush_app: "live append
                                      images, eval-render every N steps,
                                      emit PNGs to a fifo"
```

**Implementation order**:

1. Brush patch (small): add `--live-input <fifo>` and `--live-emit-eval <fifo>`
   flags so brush_app can ingest frames as they arrive instead of needing
   a complete dataset upfront. Likely ~200 LOC of Rust.
2. `live_stream_server.py`: WS endpoint, spawns brush, forwards frames in,
   forwards eval renders out.
3. iOS: WS uploader + remote-render client + overlay view.

**Effort**: 10-14 days.

### Tier A — On-Mobile (coming soon) — True on-device 3DGS training

**What you see**: A real Gaussian splat being trained on the iPhone's GPU.
You watch it form in the viewfinder over ~30 minutes — the actual blurry-
to-sharp progressive sharpening Brush shows on a Mac. No laptop needed.

**Status**: Beta, gated behind the "Coming soon" pill in the tier card.
Plan saved here so we can ship it when the timing is right.

**Files (planned)**:

```
ios_app/SplattrTrainer/             — new framework (separate target)
  Kernels/                          — MSL ports of Brush's WGSL kernels
    rasterize_forward.metal
    rasterize_backward.metal
    project_gaussians.metal
    sort_by_depth.metal             — reuse iOS Metal Performance Shaders
                                      sorting where possible
    sh_eval.metal
  TrainerSession.swift              — owns the training loop: load frames,
                                      project gaussians, rasterize, compute
                                      L1+SSIM loss, backward, Adam step
  GaussianBuffer.swift              — managed MTLBuffer of (xyz, sh, scale,
                                      rotation, opacity) tuples; supports
                                      densification + pruning callbacks
  TrainerConfig.swift               — preset matching brush_packaging_layer
                                      (draft 8k / standard 30k)
ios_app/Splattr/SplatPlayback/
  GaussianSplatRenderer.swift       — same renderer Tier D uses, but reads
                                      live from TrainerSession's buffer
                                      instead of a static PLY
ios_app/Splattr/UI/
  OnDeviceTrainView.swift           — full-screen training screen w/
                                      step counter, ETA, splat preview
```

**Implementation roadmap (3-6 weeks)**:

1. **Week 1-2**: MSL kernel ports. Brush's WGSL is closest to MSL syntactically;
   each kernel is 100-300 LOC. Validate against Brush's CPU reference test
   vectors (Brush ships them).
2. **Week 3**: GaussianBuffer + densification logic + Adam optimizer state.
   Reuse Apple's Metal Performance Shaders for the radix sort by depth.
3. **Week 4**: TrainerSession glue, frame loader, dataset shuffle.
4. **Week 5**: Memory management (iPhone Pro has 8 GB; training at 500k
   gaussians + buffers is borderline → swap inactive gaussians to disk via
   memory-mapped MTLBuffer).
5. **Week 6**: Thermal throttling handling, battery UX, "pause and resume"
   mid-training.

**Known constraints**:
- Memory: 500k-2M gaussians + grad buffers fits in 6 GB usable; >2M risks OOM.
- Thermal: continuous Metal compute throttles after ~10 min on iPhone 15.
  Mitigation: train in 10-min "spurts" with cooling pauses.
- Quality: expect lower PSNR than Brush-on-Mac at the same step count
  due to reduced batch size from memory limits.

**Why deferred**:
Tier D (post-capture on-phone playback) gives 90 % of the perceived value
for 10 % of the engineering. Build that first; ship Tier A only after
real users want it.

---

## Section 4 — Implementation order (recommended)

```
Week 1   AR-Layer 4 (pose bridge)              ← unblocks every tier above
Week 1   Tier C (Gold, textured mesh)          ← parallel; pure iOS work
Week 2   AR-Layer 5 (LiDAR → DPT-format)       ← improves splat quality
Week 2   Tier UI (selector card + persistence) ← persists tier choice
Week 3-4 Tier D (Platinum, post-cap player)    ← biggest user payoff
Week 5-6 Tier B (Max, hybrid live)             ← nice-to-have
3-6 mo   Tier A (On-Mobile, native training)   ← when product demands it
```

### Why this order

1. **Layer 4 is a hard blocker** — without it, no tier produces a real
   splat from a phone capture. Build it first.
2. **Tier C ships in parallel** — pure iOS work that touches no Python.
   It's the free-tier baseline experience and gives every user the
   "filling-in" feeling on day one.
3. **Layer 5 is independent** — improves init.ply quality. Doesn't block
   any tier; ship it anytime in week 2.
4. **Tier D before B** — D is simpler engineering and answers the most
   common user request ("show me my finished splat on the phone"). B is
   the wow-factor feature; ship after D proves the product loop.
5. **Tier A is a research project** — defer until users specifically ask
   for offline mode or for "I don't want a Mac to use this."

---

## Section 5 — Cross-cutting concerns

### Security
- LAN trust only across all tiers (matches existing Layer 0 stance).
- No auth for Tier C (no extra network).
- Tier D / Tier B / Tier A do not change the trust model — same session
  token, same LAN.

### Telemetry
Every tier emits one structured line into `metadata/<run>/tier_metrics.json`:

```json
{
  "tier": "gold|platinum|max|onmobile",
  "session_id": "...",
  "preview_engine": "textured_mesh | postcap_player | hybrid_live | onmobile_train",
  "preview_started_at_unix": 1714328700.10,
  "preview_first_frame_unix": 1714328703.45,
  "preview_p50_latency_ms": 38,
  "preview_dropped_frames": 12,
  "outcome": "completed | cancelled | network_lost | thermal_throttled"
}
```

Used to validate that each tier delivers its promised UX in real captures.

### Settings persistence
Add to `ios_app/Splattr/AppState/CaptureSettings.swift`:

```swift
enum Tier: String { case gold, platinum, max, onmobile }
extension CaptureSettings {
    static func tier() -> Tier { ... }
    static func setTier(_ t: Tier) { ... }
}
```

UserDefaults-backed; default `Tier.gold` for new installs.

### Tier gating in code
Every tier-aware screen reads `CaptureSettings.tier()` once on appear.
No hidden global state; no observer chains.

---

## Section 6 — Glossary

| Term | Meaning |
|---|---|
| accepted frame | iOS-side QualityGate said yes; JPEG + depth on disk + manifest record |
| rejected frame | QualityGate said no; only manifest record (negative-training signal) |
| AR run | a directory under `ar_runs/<id>/` produced by Layer 0+1+2+3 |
| Brush-shaped run | a directory under `runs/<id>/` produced by `upload_to_splat` and (after Layer 4) the AR pipeline; what Layer 5/6/7 train on |
| capture-package | the multipart upload from iOS to laptop server; manifest + frames + sidecars |
| dense init | `init.ply` built from depth maps before Brush training (Layer 5 of `upload_to_splat`) |
| LiDAR depth | per-frame float32 metric depth from the iPhone Pro time-of-flight sensor |
| LiDAR confidence | per-pixel uint8 reliability flag (0=low, 1=med, 2=high) |
| sceneReconstruction mesh | ARKit's own polygon mesh of the room from LiDAR + RGB |
| pose bridge | Layer 4 — converts ARKit poses to COLMAP poses |
| splat | a Gaussian splat — the final trained 3D representation |
| tier | user-visible quality preset that decides phone preview behavior |
| worldmap | ARKit's serialized session state, used for relocalization (future Layer 4 feature) |

---

*Last updated: see `git log -- ar_capture_to_splat/IMPLEMENTATION_PLAN.md` for revision history.*

---

## Section 7 — Gold Tier Perfection Plan (added 2026-05-14)

The free Gold tier ships today using Phase 1 per-anchor UIImage textures, but
the live mesh still shows blacked-out / distorted patches because (a) anchors
only ever get ONE snapshot — whatever the camera happened to see at
add-time — and (b) the Phase 2 atlas bake that would re-project the best of
several candidate views per face was parked after producing grayscale across
seven fix attempts (`project_phase2_atlas_parked.md`).

Goal: make the live 3D environment look "just like the video itself" — no
patches the user can point to and say "that's wrong."

### Why the bake produced grayscale — three plausible causes, never verified

1. **Best-view kernel rejected all views.** `MeshAtlasBaker.swift:794-830`
   has comments FIX A / FIX B / FIX C — FIX B says "that was the root cause
   of the all-grey atlas" (winding-inconsistent normals, replaced with a
   geometric facing test). Plausibly the actual fix.
2. **Candidate texture array was zero-filled.** `feedback_metal_blit_dest_usage.md`
   documents the `.shaderRead`-only blit destination bug → silent no-op blit
   → all-black sample. Fixed in `CandidateViewPool`, but never verified
   end-to-end.
3. **MTLTexture → `SCNMaterialProperty.contents` silent grayscale.**
   `feedback_scnmaterial_uiimage_path.md` documents the SCN content boundary
   that silently renders flat grey. Fixed by `mtlTextureToUIImage` at
   `MeshAtlasBaker.swift:531`, but never verified.

All three fixes are in tree. We don't know which was load-bearing because
we never had on-phone instrumentation. **Without a debug surface, the next
attempt is shot-in-the-dark #8.**

### Compute reality check

The bake does **not** hang the iPhone 15 Pro Max. `bakeAtlasChunked`
(`MeshAtlasBaker.swift:1084-1203`) already splits work into 4,096-triangle
sub-dispatches with `commit + waitUntilCompleted` between each — proven at
60 fps mid-bake on A15 (`feedback_metal_compute_yielding.md`). A17 Pro has
more headroom. Memory profile (header comment): ~144 MB + 64 MB per
already-baked atlas; a 200K-triangle room is ~336 MB peak — fine on 8 GB.
The historical "phone froze" report was the `concavePolyhedron` physics
body on the fine mesh, already fixed via 8 cm coarse weld
(`feedback_concave_polyhedron_size.md`, `MeshAtlasBaker.swift:275`).

### Plan A — Debug tool first, then re-enable atlas bake (~4-5 days)

**Phase A1 — Debug tool (~2 days)**
A new `Splattr/Debug/` module:

- **Metal Validation Layer ON.** Scheme → Diagnostics → Metal API
  Validation = Extended. Catches `.shaderRead`-on-blit-destination class
  bugs instantly. Single setting, biggest single win.
- **`DebugLog.swift`** — singleton logger mirroring every `log(...)` to
  both NSLog and `tmp/splattr_debug_<session>.log`. Tagged levels:
  `.info / .warn / .error / .gpu / .thermal`. "Share Debug Log" button uses
  `UIActivityViewController` so the log AirDrops to Mac in 3 taps.
- **`MetalDebug.swift`** — `MTLCommandBuffer.commitAndCheck(tag:)`
  extension that does commit + waitUntilCompleted + logs `cmd.error` +
  `gpuStartTime / gpuEndTime`. Universal across every dispatch.
- **`ArtifactDumper.swift`** — `dumpTexture(_:as:)`, `dumpBuffer(_:as:)`.
  During a bake we dump: each candidate texture array slice (proves
  CandidateViewPool fed real pixels in), the final atlas (proves the
  kernel wrote color), the `chosenViews` UInt16 buffer (proves best-view
  selection picked real views). All to `tmp/<session>/`.
- **`BakeDiagnostics.swift`** — `chosenViewsHistogram(_:)` returns the
  fraction of triangles that got a real view vs `0xFFFF` sentinel.
  `atlasBrightnessStats(_:)` returns mean / std / min / max — if mean
  ≈ 0.45 ± 0.001, every pixel hit the fallback grey path. **These two
  numbers tell us in seconds which of FIX A/B/C was load-bearing.**
- **`DebugHUD.swift`** — SwiftUI overlay, hidden long-press on JoinView's
  connected pill to enable. Live counters: thermal state, GPU active %
  (`MTLCounterSampleBuffer` on iOS 17+), current bake phase, sub-chunk
  timings, candidate views accepted, anchors observed, free memory
  (`os_proc_available_memory()`).
- **`ThermalObserver.swift`** — `ProcessInfo.thermalState` +
  `.thermalStateDidChangeNotification`. Logged on every change.
- **`SyntheticBakeScene.swift`** — "Run Test Bake" debug action. Feeds a
  synthetic 3-triangle scene + 1 hand-coded checkerboard view to
  `MeshAtlasBaker.bake`. Atlas should come out as checkerboard. **If it
  doesn't, problem is 100 % in the bake** — eliminates ARKit /
  CandidateViewPool as variables.

**Phase A2 — Re-enable the bake (~2-3 days, given the tool exists)**

1. Run synthetic test → atlas must be checkerboard. If not, fix until it
   is. Likely small.
2. Run on real capture → check `chosenViewsHistogram`. Expected: ≥ 90 %
   real, ≤ 10 % sentinel. If worse, relax `facing > 0.05` and `dist > 0.05`
   floors at `MeshAtlasBaker.swift:812,822`.
3. Dump first atlas PNG → open on Mac. Should look like UV-unwrapped room
   coloring. If grey, kernel never sampled. If room-colored, kernel is
   good — problem is now SCN side.
4. If atlas PNG looks correct but on-screen render is grey, the boundary
   is `mtlTextureToUIImage` or the SCN material setup in
   `MeshExplorerView`. Bypass with a direct PNG load to isolate.
5. Re-enable the bake call in `CaptureView.startExploration` (currently
   bypassed per `project_phase2_atlas_parked.md`). Keep the Phase 1
   per-anchor path as fallback if
   `BakeStats.trianglesWithView / triangleCount < 0.5`.

### Plan B — Session-end re-texture stop-gap (~2 days, low risk)

If the bake never works, this still removes ~60-80 % of black patches.

**New file: `Splattr/MeshExplorer/AnchorRetexturer.swift`**

Algorithm per anchor:
- Weakness score on `snap.textureImage`: average L + std-dev. Weak if
  `mean < 0.15` (dark) or `std < 0.05` (flat — never had real photo).
- Compute world-space centroid of the anchor's triangles.
- Iterate CandidateViewPool frames (≤ 32 per session, fast):
  - Project anchor centroids through view × projection. Count how many
    fall inside NDC `[-0.9, 0.9]` AND
    `dot(camera_forward, dir_to_centroid) > 0.2`.
  - Score by `coverage_count × sharpness / distance`.
- If best candidate scores > 1.3× current, build a fresh UIImage by
  sampling that candidate's image with planar projection (same `CIImage`
  math `TexturedMeshRenderer` already uses for first-time assignment).
  Replace `snap.textureImage`.

**Wiring**:
- `MeshExplorerView.ExplorerSceneKitView.buildScene`: call
  `AnchorRetexturer.retexture(...)` before the per-anchor SCN node loop.
- `CaptureView.startExploration`: pass `CandidateViewPool.snapshot()`
  alongside `explorerSnapshots`.

**Won't fix**: anchors literally no view ever saw (no algorithm can);
per-face MVS sharpness (still whole-anchor textures, just better ones);
inter-anchor color mismatch (separate dimension — `AnchorColorBalance`).

**Will fix**: anchors ARKit added in the periphery that never got a fresh
snapshot when the user finally aimed at them — the ~60-80 % of patches
the user is complaining about today.

### Recommended sequencing

Single ~4-5 day project: debug tool (days 1-2) → stop-gap (day 3) →
atlas bake re-enable (days 4-5).

- Stop-gap ships visible improvement to Gold even if the atlas bake
  never works — demoable in week 1, black patches mostly gone.
- Atlas bake with the debug tool in hand turns shot-in-the-dark into
  data-driven: histogram + atlas PNG dump tell us in minutes which fix
  was load-bearing and what (if anything) still fails.
- Behind tier toggle so Gold falls back to stop-gap if bake's
  `trianglesWithView` ratio is low.

### Files index (Plan A1, currently being built)
```
ios_app/Splattr/Debug/
  DebugMode.swift             — central enable flag + UserDefaults
  DebugLog.swift              — file-backed structured logger
  MetalDebug.swift            — MTLCommandBuffer.commitAndCheck extension
  ArtifactDumper.swift        — MTLTexture / MTLBuffer → tmp dir PNGs / hex
  BakeDiagnostics.swift       — chosenViews histogram + atlas stats
  ThermalObserver.swift       — ProcessInfo.thermalState observer
  DebugHUD.swift              — SwiftUI live overlay
  SyntheticBakeScene.swift    — checkerboard-scene bake test
```
Wiring touches:
- `AppState/CaptureSettings.swift` — debug-mode getter / setter
- `UI/JoinView.swift` — hidden long-press enables debug mode
- `UI/CaptureView.swift` — overlay HUD when enabled + "Share Debug Log"

