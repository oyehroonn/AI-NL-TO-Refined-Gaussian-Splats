# Future Work — Object Recognition (Phase G)

Status: **DEFERRED** as of 2026-05-14. Saved here so the spec doesn't get
lost. Will be picked up after Phase A (Gold Perfection) and Phase B
(directional guidance) ship.

## Why this isn't a "last refining fix"

ARKit's built-in mesh classification only exposes 7 labels:
`none, wall, floor, ceiling, table, seat, window, door`. That's the
entire `ARMeshClassification` enum. There's no API to ask "is this a
phone? a TV? a wallet?" — anything beyond those 7 categories requires a
separate machine-learning pipeline.

This is genuinely a 2-4 week feature, not a refining fix. Hence
saved for a later phase.

## Target object categories (user-supplied list)

Existing ARKit classes (free, already labeled per face):
- wall, floor, ceiling, table, seat, window, door

New classes to detect via CoreML:
- **Furniture additions**: chair (already covered by `seat`), couch, bed,
  desk
- **Electronics**: TV, monitor, laptop, mobile phone, tablet
- **Lighting**: ceiling light, lamp, tubelight, fan
- **Personal items**: wallet, glasses, bottle, book, notebook
- **Electrical**: power socket, light switch
- **Storage**: shelf, bookshelf, cabinet, drawer

## Architecture options

### Option A: CoreML object detection on RGB frames

Stack:
- Model: YOLOv8n converted to CoreML, ~6 MB quantized, ~40 ms inference
  on iPhone 15 Pro Max Neural Engine.
- Pipeline: every Nth ARFrame (N=10-15 → ~4-6 Hz inference), run
  detection on `arFrame.capturedImage`. Each detection produces a
  `(class, confidence, 2D bbox)`.
- 2D → 3D mapping: raycast from the detection's bbox center through
  `arFrame.camera` into the world, find the nearest ARMeshAnchor or
  classified face it hits. Stick a 3D anchor with the class label there.
- Aggregation: same detected object seen across multiple frames → cluster
  by 3D position + class; keep the highest-confidence cluster.

Pros:
- Standard CoreML pipeline; toolchain is mature.
- Runs entirely on-device. No backend changes.

Cons:
- Off-the-shelf YOLO models are trained on COCO (80 classes). Most of the
  user's target list overlaps with COCO (laptop, tv, cell phone, bottle,
  book, chair) but misses sockets, tubelights, wallets, glasses (some
  variants), fans.
- Custom fine-tune may be needed for the missed classes → dataset
  collection + training → adds another 2-3 weeks.

### Option B: ARKit anchors + Vision rectangle / contour detection for specific shapes

Stack:
- Use `VNDetectRectanglesRequest` for screens (TV, monitor, laptop lid).
- Use existing ARKit `seat`/`table` classifications + bbox heuristics
  for furniture refinement (e.g., "small table" vs "desk" by area).
- Skip the long tail (wallets, glasses, sockets) entirely.

Pros:
- No ML model to ship, no training data, no quantization.
- 10x lighter (Vision runs in microseconds).

Cons:
- Covers only ~30 % of the user's target list. Misses everything
  small / handheld.

### Option C: Hybrid (recommended)

- ARKit's 7 classes for floor / wall / ceiling / table / seat / window /
  door — already free.
- YOLOv8n COCO model for: TV, monitor, laptop, mobile phone, book,
  bottle (all COCO classes).
- Vision rectangle detection for: light switches, sockets (rectangular
  with consistent aspect).
- Custom fine-tune for: tubelight, fan, wallet, glasses (high value to
  the user, not in COCO, would need ~200-500 annotated frames each).

## UI surface

A new "OBJECTS" panel in the MeshExplorer. Tap a detected object →
camera flies to it (in FLY mode, the change just made) and a labeled
pill floats next to it. Tap-and-drag to relabel if misidentified.

Also, in the live capture HUD, a small counter: "12 OBJECTS DETECTED"
with a tap-to-list.

## Pipeline-side integration

ObjectAnchor sidecar in the manifest:
```json
{
  "objects": [
    {"class": "tv",     "confidence": 0.92, "position": [1.2, 1.4, -0.5], "bbox_3d": [[0.5, 0.9, -1.0], [1.9, 1.9, 0.0]]},
    {"class": "table",  "confidence": 1.00, "position": [-0.8, 0.0, 0.4], "source": "arkit"},
    ...
  ]
}
```

Server-side: `objects.json` written alongside `manifest.json`. Layer 7
(the AI splat analysis) can read it to give object-aware retake advice
("the laptop on the desk looks underscanned — circle around it").

## Effort estimate

| Sub-task | Days |
|---|---|
| YOLOv8n → CoreML conversion + bundling | 1 |
| Per-frame inference pipeline + 2D→3D raycast | 3 |
| Multi-frame aggregation / clustering | 2 |
| ARKit-class incorporation + Vision rectangles | 2 |
| Manifest schema + Python-side parser | 1 |
| Custom fine-tune (optional, for the 4-5 missed classes) | 5-7 |
| MeshExplorer label rendering + tap UX | 3 |
| Live capture HUD counter | 1 |
| **Subtotal** | **~17-21 days** |

## Open questions

1. **Battery / thermal**: 4-6 Hz inference on top of 60 Hz worldTracking
   + sceneReconstruction will throttle a 4-min session. May need to
   downshift to 2-3 Hz inference during scan, defer detection to a
   post-scan pass.
2. **Privacy**: detected objects are written to the laptop's
   `objects.json` and could end up in cloud-served splats. Add a
   "redact objects" toggle that strips this from upload.
3. **Multi-object clustering thresholds**: same class within 0.3 m → one
   cluster, or per-class threshold? Glasses overlap with a face;
   bottles overlap with a wallet on a table. Needs tuning data.

## When to revisit

After Phase B (directional guidance) is shipped and the user has a
clean Gold-tier workflow. Phase G is the right time — pipeline will be
mature enough that adding object metadata doesn't risk destabilising
upstream layers.
