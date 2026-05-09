//
//  AnchorColorBalance.swift
//  Option A — Global per-anchor color/exposure normalization.
//
//  The Phase 1 explorer textures each ARMeshAnchor with its own best-view
//  UIImage. Adjacent anchors are textured from DIFFERENT camera frames,
//  taken at different moments with different ARKit auto-exposure / auto-
//  white-balance states. The result: visible chunk seams where two
//  anchors meet — one wall might be greenish, the next bluish, the next
//  noticeably brighter, even though it's the same physical wall.
//
//  This is exactly the failure mode that "Let There Be Color!" (Waechter
//  et al., ECCV 2014) attacks with its global color-adjustment stage,
//  which itself follows Lempitsky & Ivanov 2007. The full Waechter
//  formulation solves a sparse linear system over per-image gain
//  coefficients minimizing the squared color-jump across every seam edge.
//
//  Option A is a pragmatic simplification: instead of solving over per-
//  seam color samples (which would require depth-aware projection of
//  every anchor-pair boundary), we solve over per-anchor MEAN colors.
//  Each anchor gets a per-channel (R, G, B) gain such that its mean
//  matches a global TARGET (the per-channel median across all anchors).
//  That single statistic captures most of the cross-anchor exposure /
//  white-balance disagreement.
//
//  Algorithm:
//    1. Compute mean RGB for every anchor's texture via CIAreaAverage
//       (GPU-accelerated; ~1 ms per anchor on iPhone Pro).
//    2. Compute per-channel median across all anchor means → target.
//    3. Per-anchor gain = clamp(target / mean, 0.5, 2.0). The clamp
//       prevents extreme corrections on outliers (a very dark anchor
//       won't be brightened 5x — that would saturate and look fake).
//    4. Apply gain via CIColorMatrix (also GPU-accelerated). Skip
//       anchors whose gain is essentially 1.0 (within 5%) — keep the
//       original UIImage for those.
//
//  Limitations vs full Waechter:
//    - Doesn't address LOCAL seam discontinuities (one anchor with bright
//      content along its left edge, dim along its right, will still
//      produce a visible jump even after mean correction).
//    - Doesn't do Poisson seam editing (we don't bake an atlas).
//    - Doesn't handle multi-view aggregation per face.
//
//  But it WILL eliminate the "every anchor is a different shade" symptom
//  visible in your scan screenshots. Step 1 of three in the Option A→C
//  ladder from the research synthesis.
//

import CoreImage
import Foundation
import UIKit
import simd

enum AnchorColorBalance {

    /// Compute per-anchor color gains and return balanced UIImages, in
    /// the same order as `snapshots`. If the snapshots already agree
    /// closely on exposure/WB, the returned images are the originals
    /// unchanged (no GPU work spent on a no-op correction).
    ///
    /// Cost: ~1 ms per snapshot for the mean computation + ~5 ms per
    /// snapshot that actually needs correction (CIColorMatrix render).
    /// For a typical room with 50 anchors → ~50-300 ms total. Runs on
    /// the call site's thread; CaptureView's startExploration is
    /// already on @MainActor and this fits in the cover-present
    /// transition.
    static func balanceAnchorTextures(
        snapshots: [TexturedMeshRenderer.ExplorerSnapshot]
    ) -> [UIImage] {
        guard !snapshots.isEmpty else { return [] }

        // CIContext shared across all per-anchor work. Hardware-rendered
        // (Metal) on iPhone — `useSoftwareRenderer: false` is the default
        // but make it explicit.
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])

        // ── 1. mean RGB per anchor ─────────────────────────────────────
        var means: [SIMD3<Float>] = []
        means.reserveCapacity(snapshots.count)
        for snap in snapshots {
            means.append(meanRGB(of: snap.textureImage, ciContext: ciContext))
        }

        // ── 2. per-channel median target ──────────────────────────────
        let target = medianRGB(means)

        // ── 3. per-anchor gain (clamped) ──────────────────────────────
        let gains: [SIMD3<Float>] = means.map { mean in
            // Floor the mean so a near-black anchor doesn't divide by
            // ~zero and produce a giant gain.
            let safeMean = SIMD3<Float>(
                max(0.05, mean.x),
                max(0.05, mean.y),
                max(0.05, mean.z)
            )
            let raw = target / safeMean
            // Clamp to a reasonable correction range. Outside this range
            // the anchor probably has fundamentally different content
            // (e.g., it caught a window or a dark crevice) and a forced
            // mean-match would do more harm than good.
            return SIMD3<Float>(
                min(2.0, max(0.5, raw.x)),
                min(2.0, max(0.5, raw.y)),
                min(2.0, max(0.5, raw.z))
            )
        }

        // ── 4. apply gains (skip near-identity gains) ──────────────────
        var result: [UIImage] = []
        result.reserveCapacity(snapshots.count)
        for (i, snap) in snapshots.enumerated() {
            let g = gains[i]
            // Skip if all three channels are within 5% of 1.0.
            if abs(g.x - 1) < 0.05 &&
               abs(g.y - 1) < 0.05 &&
               abs(g.z - 1) < 0.05 {
                result.append(snap.textureImage)
                continue
            }
            if let balanced = applyGain(g,
                                         to: snap.textureImage,
                                         ciContext: ciContext) {
                result.append(balanced)
            } else {
                // Fall back to the original — applying a no-op is better
                // than dropping the anchor's color entirely on a render
                // failure.
                result.append(snap.textureImage)
            }
        }
        return result
    }

    // MARK: - Internal

    /// CIAreaAverage reduces an image to a 1×1 pixel containing the mean
    /// R, G, B, A values. Runs as a Metal compute pass on iPhone — much
    /// faster than iterating pixels in Swift.
    private static func meanRGB(
        of image: UIImage,
        ciContext: CIContext
    ) -> SIMD3<Float> {
        guard let ciImage = CIImage(image: image) else {
            return SIMD3(0.5, 0.5, 0.5)
        }
        let extent = ciImage.extent
        let extentVector = CIVector(x: extent.origin.x,
                                     y: extent.origin.y,
                                     z: extent.size.width,
                                     w: extent.size.height)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                     parameters: [
                                        kCIInputImageKey: ciImage,
                                        kCIInputExtentKey: extentVector
                                     ]),
              let output = filter.outputImage else {
            return SIMD3(0.5, 0.5, 0.5)
        }
        var bitmap: [UInt8] = [0, 0, 0, 0]
        ciContext.render(output,
                          toBitmap: &bitmap,
                          rowBytes: 4,
                          bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                          format: .RGBA8,
                          colorSpace: CGColorSpaceCreateDeviceRGB())
        return SIMD3<Float>(
            Float(bitmap[0]) / 255.0,
            Float(bitmap[1]) / 255.0,
            Float(bitmap[2]) / 255.0
        )
    }

    /// Per-channel median across an array of RGB triples. Robust to the
    /// occasional outlier anchor (e.g., one that caught a bright window
    /// in its texture); the median absorbs the outlier without dragging
    /// the target away from where most anchors live.
    private static func medianRGB(_ rgbs: [SIMD3<Float>]) -> SIMD3<Float> {
        guard !rgbs.isEmpty else { return SIMD3(0.5, 0.5, 0.5) }
        let rs = rgbs.map { $0.x }.sorted()
        let gs = rgbs.map { $0.y }.sorted()
        let bs = rgbs.map { $0.z }.sorted()
        let mid = rs.count / 2
        return SIMD3<Float>(rs[mid], gs[mid], bs[mid])
    }

    /// Apply per-channel gain via CIColorMatrix. The diagonal-matrix form
    /// scales each channel independently:
    ///     R' = gain.x * R
    ///     G' = gain.y * G
    ///     B' = gain.z * B
    ///     A' = A
    /// CoreImage applies this in its working color space (linear RGB),
    /// which matches the perceptual intent — multiplying linear-light
    /// values is the right operation for exposure correction.
    private static func applyGain(
        _ gain: SIMD3<Float>,
        to image: UIImage,
        ciContext: CIContext
    ) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        guard let filter = CIFilter(name: "CIColorMatrix") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: CGFloat(gain.x), y: 0, z: 0, w: 0),
                        forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: CGFloat(gain.y), z: 0, w: 0),
                        forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: CGFloat(gain.z), w: 0),
                        forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1),
                        forKey: "inputAVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0),
                        forKey: "inputBiasVector")
        guard let output = filter.outputImage else { return nil }
        guard let cg = ciContext.createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
