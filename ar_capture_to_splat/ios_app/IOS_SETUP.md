# Splattr — iOS setup (run on your iPhone)

Goal: scan the laptop's QR with your iPhone's camera and have **Splattr** open
directly (instead of Safari showing the landing page).

You need: a Mac with **Xcode 15.0+**, an **Apple ID** (free is fine), and a
**Lightning/USB-C cable** to plug the iPhone into the Mac the first time.

You **do not** need an Apple Developer Program membership ($99/yr).

---

## 1. One-time Xcode setup (≈3 minutes)

1. Open `ar_capture_to_splat/ios_app/Splattr.xcodeproj` (double-click it).
2. In the left sidebar, click the blue project icon **Splattr** at the top.
3. Pick the **Splattr** target → **Signing & Capabilities** tab.
4. **Team** dropdown → choose **Add an Account…** if your Apple ID isn't there
   yet. Sign in with your Apple ID. Then back in **Team**, pick
   `<Your Name> (Personal Team)`.
5. **Bundle Identifier** is `com.splattr.capture`. If Xcode complains it's
   already in use (someone on a shared team registered it), change the suffix
   — e.g. `com.splattr.capture.<yourinitials>`. The custom URL scheme stays
   `claudesplat`, so the QR keeps working.
6. Plug your iPhone into the Mac with a cable.
7. **Trust this Mac?** → Trust on the iPhone, enter passcode.
8. In Xcode's top bar, the device picker (next to the Run button) → choose
   your iPhone (not a simulator — the simulator can't talk to your laptop's
   LAN IP cleanly).
9. Press the **Run** button (▶) or `⌘R`.

First build takes ~30s. Xcode installs Splattr on the iPhone.

10. On the iPhone, open **Settings → General → VPN & Device Management →
    Developer App → <your Apple ID>** → tap **Trust**. Confirm.
11. Open Splattr from the home screen once to make sure it launches. You'll
    see the splash with the halo + "scan. capture. splat." headline.

You're done. Unplug.

> **Free-team caveat**: a free-Apple-ID build expires every **7 days**. To
> reinstall: re-plug the iPhone, hit Run again. No code changes needed.

---

## 2. Run the loop end-to-end

On the **Mac**:

```bash
python -m pipeline.run_pipeline
# choose 2) Record a new video on iPhone
# enter capture name (e.g. "kitchen_test")
# pick scene type (1 = room)
```

A QR appears (terminal ASCII + a PNG opens in Preview).

On the **iPhone** (same WiFi as the Mac):

1. Open the **Camera** app, point it at the QR.
2. Tap the yellow notification banner. iOS now offers `Open in "Splattr"`.
3. Tap it → Splattr launches into the **Join** screen with the run name.
4. Tap **Begin Capture** → it grabs 30 frames over ~18 s.
5. Goes to **Upload** → progress ring fills → **Capture Delivered**.

On the Mac terminal: server prints `Capture received: 30 frames…` and shuts
down. Files land at:

```
ar_runs/run<N>__<slug>/
  capture/
    manifest.json
    frames/frame_000000.jpg … frame_000029.jpg
  metadata/
    capture_session.json
    capture_manifest.json
```

---

## 3. Troubleshooting

### Camera tap on QR opens Safari, not Splattr
- Splattr isn't installed yet, or hasn't been opened once. Re-do step 11
  above (open Splattr from the home screen at least once).
- Make sure the deep-link QR (the **first** QR printed by the laptop) is
  the one you scanned, not the http fallback PNG.

### "Couldn't reach the laptop session at 192.168.x.y" inside Splattr
- iPhone and laptop must be on the **same WiFi**.
- macOS firewall: System Settings → Network → Firewall → Options →
  allow incoming connections for **python3** (or the Terminal binary you
  ran the pipeline from).
- Some campus / hotel WiFis block client-to-client traffic. Try a hotspot.

### "Camera permission denied"
- Settings → Splattr → Camera → on.

### Build fails: "Signing for 'Splattr' requires a development team"
- Step 4 above. Pick your personal team.

### Build fails: "Failed to register bundle identifier"
- Bundle id collision (rare, but happens on shared teams). Step 5: rename
  the suffix.

### App crashes on launch on a phone older than iPhone XR
- Deployment target is iOS 17.0. Use a newer device or change the target
  in `project.pbxproj` (`IPHONEOS_DEPLOYMENT_TARGET`) — but iOS 16 lacks
  some SwiftUI features the design system uses.

### `xcodebuild -list` errors about CoreSimulator on the Mac
- Apple housekeeping. Run once: `xcodebuild -runFirstLaunch`. Doesn't
  affect device builds.

---

## 4. What the app currently does (and what it doesn't, yet)

**Done (AR-Layer 0 iOS)**:
- Custom URL scheme `claudesplat://` → app launches from QR.
- Pulls session from `GET /session`.
- 30 frames via `AVCaptureSession` (plain camera).
- Multipart upload to laptop matching `CAPTURE_PROTOCOL.md`.
- Premium dark UI (halo, glass cards, neon ring, scanning bar).

**Coming (AR-Layer 1 / 2 / 3)**:
- Real animated tutorial (scene-aware).
- ARKit `ARWorldTrackingConfiguration` capture: per-frame pose +
  intrinsics + tracking-state gating.
- LiDAR `sceneDepth` upload (iPhone Pro / Pro Max only).
- Coverage HUD (live "fog" mask filling in as you cover the scene).
