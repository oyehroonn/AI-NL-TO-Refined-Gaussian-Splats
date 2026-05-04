# Capture Protocol — AR-Layer 0

Stable contract between the laptop session server and the iOS capture app.
Layer 0 is the transport. The iOS app implementation (AR-Layer 1+) MUST conform.

---

## 1. Handoff (QR payload)

The QR encodes a single URL. To support both deep-linking into a future iOS
app and a plain browser fallback, the laptop generates **two** QR images:

- **primary** (custom scheme — for the iOS app):
  `claudesplat://join?session=<session_id>&host=<ip>:<port>&v=1`
- **fallback** (http — opens in mobile Safari, useful for testing):
  `http://<ip>:<port>/join?session=<session_id>&v=1`

Both encode the same routing info. The iOS app, when it exists, will register
`claudesplat` as a URL scheme and intercept the primary form.

`v=1` is the protocol version; bump on breaking changes.

---

## 2. Server endpoints

All paths are rooted at `http://<ip>:<port>`.

### `GET /healthz`
Liveness probe. Returns `200 OK` with body `ok`. No auth.

### `GET /session`
Returns the current session descriptor as JSON. Used by the iOS app right
after scanning, to confirm it is talking to the right session before showing
the tutorial.

```json
{
  "session_id": "a1b2c3d4",
  "run_id": "run3__kitchen_counter",
  "video_name": "kitchen_counter",
  "protocol_version": 1,
  "scene_type_default": "room",
  "expires_at_unix": 1714329600
}
```

### `GET /tutorial-config?scene_type=<name>`
Stub for AR-Layer 1. Returns scene-specific capture tips. Layer 0 ships
placeholder copy; AR-Layer 1 replaces the content.

```json
{
  "scene_type": "room",
  "tips": [
    "Move slowly, walk sideways — don't just rotate.",
    "Cover near and far views.",
    "Tilt up, mid, down.",
    "Revisit corners and occluded areas.",
    "Stop when coverage is full, not when the timer is long."
  ]
}
```

If `scene_type` is unknown, returns the `room` set with `"scene_type":
"<requested>", "fallback": true`.

### `GET /join?session=<id>&v=1`
Friendly landing page hit by mobile Safari (fallback URL). Layer 0 returns
a minimal HTML page that says "Capture session active. Open the
ClaudeSplat app to continue." Mostly diagnostic.

### `POST /upload`
Multipart upload of the capture package. **The single most important
endpoint.** Body must be `multipart/form-data` with these parts:

| Part name          | Filename pattern                  | Content-Type    | Required | Notes |
|--------------------|-----------------------------------|-----------------|----------|-------|
| `session_id`       | (form field)                      | text/plain      | yes      | Must match `/session` |
| `manifest`         | `manifest.json`                   | application/json | yes     | See §3 |
| `frames`           | `frames/frame_<N>.jpg`            | image/jpeg      | yes (1+) | One part per accepted frame |
| `depth`            | `depth/frame_<N>.bin`             | application/octet-stream | optional | Per-frame raw depth (when LiDAR present) |
| `depth_smoothed`   | `depth_smoothed/frame_<N>.bin`    | application/octet-stream | optional | smoothedSceneDepth |
| `depth_confidence` | `depth_confidence/frame_<N>.bin`  | application/octet-stream | optional | uint8 confidence map (0/1/2 per ARDepthData) |
| `feature_points`   | `feature_points/frame_<N>.bin`    | application/octet-stream | optional | rawFeaturePoints — sparse cloud + persistent IDs |
| `world_map`        | `world_map.arworldmap`            | application/octet-stream | optional | NSKeyedArchiver ARWorldMap (consumed by AR-Layer 4) |
| `mesh`             | `scene_mesh.obj` or `.ply`        | application/octet-stream | optional | sceneReconstruction polygon mesh, world-space |
| `rejected_frames`  | `rejected_frames.json`            | application/json | optional | Negative-training signal: per-rejected-frame metadata + reject reason |
| `thumbnail`        | `thumbnail.jpg`                   | image/jpeg      | optional | One picked still for UI use |

The server validates that:
- `session_id` matches the active session (else 403).
- `manifest.json` parses, has the required fields below, and the per-frame
  `image_path` / `scene_depth_path` references match part filenames present
  in the upload (else 400 with a list of mismatches).
- Total upload size ≤ `MAX_UPLOAD_BYTES` (default 4 GiB; configurable).
- Filenames have no `..` or absolute prefixes (path-traversal guard).

On success the server moves files into `ar_runs/<run_id>/capture/` and
returns:

```json
{
  "ok": true,
  "run_id": "run3__kitchen_counter",
  "frames_received": 184,
  "depth_received": 184,
  "smoothed_depth_received": 184,
  "confidence_received": 184,
  "feature_points_received": 184,
  "rejected_frames_count": 92,
  "has_world_map": true,
  "has_mesh": true,
  "tracking_state_breakdown": {"normal": 178, "limited": 6, "notAvailable": 0}
}
```

After a successful upload the server signals capture-complete and shuts
down (orchestrator returns `run_dir` to the dispatcher). Re-uploads to the
same session will return `409 Conflict`.

---

## 3. Manifest schema

`manifest.json` is the authoritative description of the capture. It is the
contract the iOS app (AR-Layer 3) must produce.

```json
{
  "schema_version": 1,
  "session_id": "a1b2c3d4",
  "run_id": "run3__kitchen_counter",
  "video_name": "kitchen_counter",
  "scene_type": "room",
  "started_at_unix": 1714328700.10,
  "ended_at_unix":   1714328823.42,
  "device": {
    "model": "iPhone15,2",
    "os": "iOS 17.4",
    "lidar_supported": true,
    "scene_reconstruction_supported": true,
    "ar_world_tracking_configuration": {
      "video_format": {"width": 1920, "height": 1440, "fps": 60},
      "frame_semantics": ["sceneDepth", "smoothedSceneDepth"],
      "plane_detection": ["horizontal","vertical"],
      "scene_reconstruction": "meshWithClassification"
    }
  },
  "summary": {
    "frames_captured": 540,
    "frames_kept": 184,
    "duration_seconds": 123.32,
    "tracking_state_breakdown": {"normal": 178, "limited": 6, "notAvailable": 0},
    "world_mapping_status_breakdown": {"mapped": 122, "extending": 60, "limited": 2, "notAvailable": 0},
    "coverage_summary": {
      "covered_fraction": 0.78,
      "weak_regions": [
        {"label": "ceiling_back_left", "score": 0.31}
      ]
    },
    "preview_run": false,
    "enhance_run": false
  },
  "frames": [
    {
      "frame_id": 184,
      "timestamp": 1714328823.42,
      "image_path": "frames/frame_000184.jpg",
      "camera_transform_world": [[r00,r01,r02,tx],[r10,r11,r12,ty],[r20,r21,r22,tz],[0,0,0,1]],
      "camera_intrinsics": [[1612.3, 0, 960.0],[0, 1612.3, 720.0],[0,0,1]],
      "image_width": 1920,
      "image_height": 1440,
      "tracking_state": "normal",
      "tracking_reason": null,
      "world_mapping_status": "extending",
      "light_estimate": {
        "ambient_intensity": 921.0,
        "ambient_color_temperature": 5400.0
      },
      "raw_feature_points_count": 1832,
      "has_scene_depth": true,
      "scene_depth_path": "depth/frame_000184.bin",
      "smoothed_scene_depth_path": "depth_smoothed/frame_000184.bin",
      "depth_confidence_path": "depth_confidence/frame_000184.bin",
      "feature_points_path":   "feature_points/frame_000184.bin",
      "pose_quality_score": 0.93,
      "blur_score": 142.5,
      "coverage_score": 0.71,
      "captured_high_resolution": true,
      "exposure": {
        "exposure_duration_seconds": 0.0166,
        "exposure_offset_stops": -0.3
      },
      "exif": {
        "iso": 320,
        "shutter_speed_seconds": 0.0166,
        "white_balance_rgb_gains": [1.94, 1.0, 1.62],
        "lens_position": null
      },
      "accepted_for_training": true,
      "reject_reason": null
    }
  ],
  "world_map_path":        "world_map.arworldmap",
  "mesh_path":             "scene_mesh.obj",
  "rejected_frames_path":  "rejected_frames.json"
}
```

### Required per-frame fields (accepted frames)
`frame_id`, `timestamp` (Unix epoch seconds — *not* ARFrame.timestamp mach time),
`image_path`, `camera_transform_world` (4×4 row-major, ARKit world-frame → camera),
`camera_intrinsics` (3×3), `image_width`, `image_height`,
`tracking_state` (`normal` | `limited` | `notAvailable`),
`accepted_for_training` (true).

### Required per-frame fields (rejected frames)
`frame_id`, `timestamp`, `tracking_state`, `accepted_for_training` (false),
`reject_reason`. **No** `image_path`, `image_width`, `image_height`, or
`camera_*` fields are required for rejected frames — ARKit metadata is
typically still included, but the JPEG/depth payloads are not staged on disk.

### Optional per-frame fields
`tracking_reason` (only when `tracking_state == "limited"`: `initializing` |
`relocalizing` | `excessiveMotion` | `insufficientFeatures` | `none`),
`world_mapping_status` (`mapped` | `extending` | `limited` | `notAvailable`),
`light_estimate`, `raw_feature_points_count`, `has_scene_depth`,
`scene_depth_path`, `smoothed_scene_depth_path`, `depth_confidence_path`,
`feature_points_path`, `pose_quality_score`, `blur_score`, `coverage_score`,
`captured_high_resolution`, `exposure`, `exif`, `reject_reason`.

### Required session-level fields
`schema_version`, `session_id`, `run_id`, `started_at_unix`,
`ended_at_unix`, `device.model`, `summary.frames_kept`, `frames`.

### Optional session-level fields
`world_map_path`, `mesh_path`, `rejected_frames_path` — references to the
sidecar parts in §2 (e.g. `"world_map.arworldmap"`, `"scene_mesh.obj"`,
`"rejected_frames.json"`). Each is set when its corresponding multipart
part was uploaded; absent or null otherwise.

### Per-frame binary side-car formats

All per-frame `.bin` files use a 16-byte little-endian header followed by a
raw payload. Layer 0 stores the blob unchanged; downstream layers parse it.

**Depth (`depth/`, `depth_smoothed/`)** — `float32` row-major depth.
Header: `uint32 width, uint32 height, uint32 stride_bytes, uint32 reserved`.
Reader **must** use `stride_bytes` (not `width*4`) to honour any pixel-buffer
padding ARKit may introduce in future formats.

**Depth confidence (`depth_confidence/`)** — `uint8` row-major. Values are
ARDepthData confidence levels: `0` = low, `1` = medium, `2` = high. Same
header as depth.

**Raw feature points (`feature_points/`)** —
Header: `char[4]='FPTS', uint32 count, uint64 reserved`. Then
`count × { float32 x, float32 y, float32 z, uint64 identifier }` (20 bytes
per point). The `identifier` is ARKit's persistent feature ID across frames
— useful for triangulation/track linking in COLMAP-style ingest.

### Top-level sidecars

**`world_map.arworldmap`** — `NSKeyedArchiver`-encoded `ARWorldMap`. iOS
writes this via `ARSession.getCurrentWorldMap` at session end. Consumed by
AR-Layer 4 (pose bridge) for world-coordinate alignment and relocalization.

**`scene_mesh.obj`** — Wavefront OBJ snapshot of every active `ARMeshAnchor`
on `session.currentFrame.anchors`, vertices transformed to world space.
Includes per-vertex normals when ARKit provides them and `g class_<n>`
groups when `meshWithClassification` is enabled. AR-Layer 5 may use this as
a dense init prior in addition to (or in place of) DPT depth maps.

**`rejected_frames.json`** — JSON array of every frame the iOS QualityGate
dropped, with timestamp, tracking state, reject reason, blur score, etc.
Negative-training signal for downstream filtering policy tuning.

---

## 4. Failure modes

| Scenario | Server response |
|---|---|
| Missing `session_id` part or mismatch | 403 |
| Manifest malformed | 400 with `{"error":"manifest_parse","detail":"..."}` |
| Required frame fields missing | 400 with list of offending frame_ids |
| File referenced in manifest but not present in multipart | 400 with list of missing paths |
| File present but not referenced | 400 (strict; encourages the iOS side to keep the manifest authoritative) |
| Total bytes > MAX_UPLOAD_BYTES | 413 |
| Duplicate upload to same session | 409 |
| Server already shut down (race) | connection refused |

---

## 5. Out of scope for Layer 0

- Auth (no tokens, no signed URLs — LAN trust only).
- Cloud relay / WAN access (LAN-only).
- Resumable / chunked upload (single multipart POST for now).
- Real-time streaming during capture (the iPhone batches and uploads at end).
- Ack of partial frames.

These are tracked for AR-Layer 1+ in `system_progress.md`.

---

## 6. `capture_policy` (added by AR-Layer 1)

Optional top-level field in `manifest.json`. The Splattr iOS app fills it
from the `CaptureMode` the user confirmed in the tutorial. Layer 0 parses
it leniently — missing or malformed never blocks an upload, but the server
logs a warning. AR-Layer 4 (pose bridge) reads it to choose reconstruction
defaults; Layer 7 (AI report) reads it to phrase advice in mode-appropriate
language.

```jsonc
"capture_policy": {
  "scene_type": "room",
  "scan_mode": "room_perimeter_sweep",        // policy id, NOT scene_type
  "path_pattern": "perimeter_then_center",     // see allowed values below
  "frame_budget": { "min": 60, "target": 200, "max": 320 },
  "coverage_targets": {
    "min_directions_8": 6,                     // out of 8 compass sectors
    "min_orbit_score": 0.55,
    "loop_closure_required": true
  },
  "distance_band_meters": { "near": 1.0, "far": 6.0 },
  "movement": {
    "max_speed_mps": 0.4,
    "expect_translation": true,
    "expect_rotation_only": false
  },
  "ar_features_required":  ["worldTracking"],
  "ar_features_preferred": ["sceneDepth", "smoothedSceneDepth", "sceneReconstruction"],
  "tutorial_run": true,
  "tutorial_skipped": false,
  "policy_version": 1
}
```

### Allowed `path_pattern` values
`orbit`, `spiral`, `perimeter_then_center`, `corridor_forward_back`,
`facade_sweep`, `wide_arc`, `rotation_only_object`.

### Defaults when absent
The Python `parse_capture_policy()` helper returns `None`; downstream
layers fall back to a generic room-mode default (`perimeter_then_center`,
near=1.0, far=6.0, frame target=180).
