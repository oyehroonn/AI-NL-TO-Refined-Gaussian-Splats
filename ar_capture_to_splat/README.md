# AR-Capture-to-Splat (Pipeline B)

> Record a room with your iPhone. Watch the geometry fill in live. Hand off
> to your Mac. Get a trained Gaussian splat back. All in under an hour.

This is the **iPhone-native** half of the project — an iOS app called
**Splattr** + a laptop session server + a tiered preview system that
takes you from "open the app" to "trained splat in your hand."

---

## What you get

```
   iPhone (Splattr app)              Laptop (this repo)
   ─────────────────────             ─────────────────────────────────
                                                                    
   📱  scan QR                  ──→  🖥️  session server (Layer 0)     
       ↓                                                              
   📚  pick scene type          ←──  📋 tutorial config              
       (room/object/corridor/8 modes)                                  
       ↓                                                              
   🎓  swipeable tutorial                                              
       ↓                                                              
   🔴  AR capture (ARKit, LiDAR, sceneReconstruction)                  
       ↓ live: textured mesh "fills in" your room                      
       ↓ live: coverage HUD shows what you've covered                  
       ↓ live: tracking + mapping state guidance                       
       ↓                                                              
   📦  capture-package built (manifest + frames + sidecars)            
       ↓                                                              
   📡  multipart upload         ──→  💾 ar_runs/<id>/capture/         
                                          ↓                            
                                     🔧 AR-Layer 4: pose bridge       
                                       (ARKit poses → COLMAP)         
                                          ↓                            
                                     🚀 Existing layers 5/6/7 train   
                                          ↓                            
                                     📦 trained .ply at               
                                        runs/<id>/outputs/output_ply/  
       ↓                                                              
   🖼️  view splat (depending on tier)                                  
```

---

## The tier system

How and where the splat is rendered to **you on your phone** depends on
which tier you've picked. All four tiers produce the same final `.ply`;
they differ only in the live preview experience and the playback UX.

| Tier | Price | What you see during capture | Where the splat trains | Phone playback |
|---|---|---|---|---|
| 🥇 **Gold** | Free | Live LiDAR mesh in viewfinder, **textured with your camera feed** — the room fills in with real-world appearance as you scan | Laptop, post-capture | Open `.ply` in Brush on your laptop |
| 💎 **Platinum** | $X | Same Gold preview during capture, **plus** a "View Splat" screen on the phone after laptop training finishes | Laptop, post-capture | **Brush-style splat viewer on your phone** — orbit, pinch, place in your room |
| 🚀 **Max** | $XX | **Real splat being trained on the laptop streamed back to your phone in real time** — the "Brush in your viewfinder" experience | Laptop, real-time stream | Same on-phone viewer as Platinum |
| 🤖 **On-Mobile** | _Coming soon (Beta)_ | **Real Gaussian splat training on your phone** — actual blurry-to-sharp progressive sharpening, no laptop needed | Phone | Native, always |

**Pick your tier in the JoinView "Quality" card** right before you start
capturing. The choice is persisted to UserDefaults so future sessions
default to your last pick.

> Full implementation plans for each tier are in
> [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md).

---

## Quick start

### Prerequisites

- **iPhone with LiDAR** (iPhone 12 Pro or newer Pro / Pro Max). Non-LiDAR
  iPhones work but you lose depth + sceneReconstruction (Gold tier
  becomes flat-colored mesh, not textured).
- iOS 17+
- A **Mac** running this repo's laptop pipeline.
- Same WiFi network for both. (LAN-only for now; cellular relay is on
  the roadmap.)

### One-time iOS app setup

Follow [`ios_app/IOS_SETUP.md`](ios_app/IOS_SETUP.md) — Xcode signing
with a free Apple ID, install on device, accept the developer cert in
Settings → General → VPN & Device Management.

### Laptop side — start a capture session

```bash
# From the repo root
python3 -m ar_capture_to_splat.scripts.session_layer.run_layer0 \
  --scene-type room
```

This opens an HTTP server on your LAN (default port 8765), prints two
QR codes (deep-link + http fallback), and waits for an upload.

```
Splattr session ready
─────────────────────
Session ID:  a1b2c3d4
Run dir:     ar_runs/run7__myroom/
Listening:   http://192.168.1.107:8765/

[QR: claudesplat://join?session=a1b2c3d4&host=192.168.1.107:8765&v=1]

Waiting for capture upload…
```

### Phone side

1. Open **Splattr** on the iPhone.
2. Scan the QR shown on your laptop screen.
3. Pick a scene type (room / object / small_object_turntable / corridor /
   storefront / outdoor_facade / vehicle / large_indoor).
4. Walk through the swipeable tutorial.
5. Pick your **Quality** tier (Gold / Platinum / Max / On-Mobile soon).
6. Tap **Begin Capture**, sweep the room with the recommended motion
   pattern. Watch the mesh fill in.
7. Tap **Stop & Upload**. The capture-package multiparts to the laptop.

### Laptop side — after upload

The session server prints something like:

```
Capture received: 184 frames, depth=184, tracking={'normal':178,'limited':6}
Run dir: /Users/.../ar_runs/run7__myroom

Capture saved to: /Users/.../ar_runs/run7__myroom
Next: AR-Layer 4 (pose bridge) will turn this into a COLMAP-shaped run that
the existing splat pipeline can train on.
```

When **AR-Layer 4** is implemented (see [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md)):

```bash
python3 -m ar_capture_to_splat.scripts.pose_bridge_layer.run_layer4 \
  --ar-run-dir ar_runs/run7__myroom
# → produces runs/A3__myroom/
# → which then trains via the standard pipeline
```

---

## The AR layers

| Layer | Where | Status | What it does |
|---|---|---|---|
| **AR-Layer 0** | `scripts/session_layer/` | ✅ shipped | QR + HTTP server + multipart receiver + session lifecycle |
| **AR-Layer 1** | `scripts/capture_policy_layer/` + iOS `CapturePolicy/` | ✅ shipped | 8 scene-type modes, capture-policy schema, in-app tutorial |
| **AR-Layer 2** | iOS `Capture/` | ✅ shipped | ARSession + per-frame pose/intrinsics/depth/tracking, coverage grid, loop detection |
| **AR-Layer 2.5** | iOS `Capture/MeshLiveRenderer.swift` | ✅ shipped | Live sceneReconstruction mesh overlay during capture |
| **AR-Layer 3** | iOS `Networking/ManifestUploader.swift` + `scripts/session_layer/server.py` | ✅ shipped | Capture-package builder + multipart upload + manifest validation |
| **AR-Layer 4** | `scripts/pose_bridge_layer/` _(planned)_ | 🟡 next | ARKit poses → COLMAP `cameras.bin`/`images.bin`/`points3D.bin` |
| **AR-Layer 5** | `scripts/lidar_depth_layer/` _(planned)_ | 🟡 follows L4 | LiDAR depth + confidence → DPT-format for dense init |
| **Tier system** | iOS `AppState/` + `UI/TierSelector.swift` _(planned)_ | 🟡 follows L4 | Gold / Platinum / Max / On-Mobile selector + persistence |

### What each layer produces

```
ar_runs/<id>/
  capture/                                    ← AR-Layer 0 + 3
    manifest.json                             ← schema in CAPTURE_PROTOCOL.md
    frames/frame_<N>.jpg                      ← AR-Layer 2 + 3 (HR when supported)
    depth/frame_<N>.bin                       ← LiDAR float32 (16-byte header)
    depth_smoothed/frame_<N>.bin              ← smoothedSceneDepth
    depth_confidence/frame_<N>.bin            ← uint8 0/1/2
    feature_points/frame_<N>.bin              ← rawFeaturePoints (FPTS magic)
    world_map.arworldmap                      ← NSKeyedArchiver ARWorldMap
    scene_mesh.obj                            ← sceneReconstruction snapshot
    rejected_frames.json                      ← negative-training signal
  metadata/
    capture_session.json                      ← AR-Layer 0
    capture_manifest.json                     ← post-upload summary
  logs/layer0.log
```

After **AR-Layer 4 + 5** ship:

```
runs/A3__myroom/                              ← AR-Layer 4 output
  sparse/0/cameras.bin, images.bin, points3D.bin
  images/                                     ← copies of capture/frames/
  dpt/                                        ← AR-Layer 5: LiDAR-derived
  metadata/layer4_pose_bridge.json
  …
```

…at which point the existing `upload_to_splat` Layer 5/6/7 train on it
and produce `runs/A3__myroom/outputs/output_ply/export_*.ply`.

---

## Capture protocol contract

The wire format between iOS and the laptop server is in
[`scripts/session_layer/CAPTURE_PROTOCOL.md`](scripts/session_layer/CAPTURE_PROTOCOL.md).
That's the source of truth for:

- Multipart part names + filename patterns
- Per-frame manifest fields (required vs optional)
- Binary side-car formats (depth header, feature-points layout)
- Top-level sidecars (worldmap, mesh, rejected-frames)
- Failure modes and HTTP status codes

When you change the iOS app or the Python server, update the protocol
doc in the same commit.

---

## Privacy + security posture

- **LAN-only** — the laptop server binds to `0.0.0.0:<port>` on your local
  network. No cloud relay yet.
- **No accounts, no auth tokens** — session lifetime is one upload.
  Re-uploads to the same session return `409 Conflict`.
- **Path-traversal guarded** — every multipart filename is regex-matched
  before being written to disk.
- **No telemetry** — captures stay between your phone and your laptop.

A WAN relay (so your phone doesn't need to be on the same WiFi) is on
the roadmap; when it ships, signed URLs + per-session tokens will be
added.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| QR scan does nothing | iOS doesn't have the `claudesplat://` scheme registered | Reinstall the app, or scan the http-fallback QR (works in mobile Safari) |
| Server says "couldn't reach" | Different WiFi networks | Same-LAN required; check both devices |
| Upload fails with `manifest_bad_frames` | Stale iOS build, schema mismatch | Rebuild app with current `Manifest.swift` |
| Camera permission denied | iOS settings | Settings → Splattr → Camera → On |
| Local network permission denied | iOS settings | Settings → Splattr → Local Network → On |
| App icon missing in Xcode | Empty AppIcon set | Drop a 1024×1024 PNG in `Splattr/Assets.xcassets/AppIcon.appiconset/` |
| Build fails: "Signing for 'Splattr' requires a development team" | Xcode signing not set up | Follow [`ios_app/IOS_SETUP.md`](ios_app/IOS_SETUP.md) |
| Capture acceptance rate seems too low | QualityGate too strict for your motion | See `Capture/QualityGate.swift` thresholds; defaults are tuned for handheld HR-mode |

---

## Related docs

- [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) — the live engineering
  plan for AR-Layer 4 / 5 and the tier system
- [`scripts/session_layer/CAPTURE_PROTOCOL.md`](scripts/session_layer/CAPTURE_PROTOCOL.md) —
  iOS↔laptop wire contract
- [`ios_app/IOS_SETUP.md`](ios_app/IOS_SETUP.md) — Xcode signing + run-on-device

---

*Status: Layers 0–3 + Layer 2.5 shipped. Layer 4 (pose bridge) is the next
implementation unit. See [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md)
for the timeline.*
