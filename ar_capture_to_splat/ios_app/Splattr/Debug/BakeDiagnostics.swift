//
//  BakeDiagnostics.swift
//  Splattr — Gold Tier Perfection (Phase A1, debug surface).
//
//  Pure functions over the bake's intermediate state. These two numbers
//  in particular tell us in seconds which of MeshAtlasBaker's
//  FIX A / FIX B / FIX C (the three independent "all-grey atlas" fixes
//  shipped without verification) was actually load-bearing:
//
//   * chosenViewsHistogram → fraction of triangles that got a real view
//     vs the 0xFFFF sentinel. If >50% sentinel, the kernel is rejecting
//     too many views → the bug is in selectBestView's filters. If <10%
//     sentinel, the kernel picked real views and the atlas SHOULD have
//     color — if it doesn't, the bug is downstream of the kernel.
//
//   * atlasBrightnessStats → mean / std / min / max of the atlas image
//     pixels. If mean ≈ 0.45 ± 0.001, every pixel hit the grey fallback
//     path (the hard-coded `grey = float4(0.45, 0.45, 0.50, 1.0)` at
//     `MeshAtlasBaker.swift:1032`). Mean far from 0.45 + std > 0.05 →
//     the kernel sampled real frames into the atlas. Open the dumped PNG
//     to see what was sampled.
//
//  Output: a single ChosenViewsReport / AtlasBrightnessReport struct each
//  caller can stash in BakeStats and log. ArtifactDumper.dumpText is the
//  recommended way to ship a formatted version off-device alongside the
//  atlas PNG.
//

import Foundation
import Metal
import UIKit

// MARK: - Chosen views

struct ChosenViewsReport: CustomStringConvertible {
    /// Total triangles inspected.
    let total: Int
    /// Triangles where chosenView == 0xFFFF (sentinel = no view picked).
    let sentinelCount: Int
    /// Highest non-sentinel view index encountered.
    let maxViewIndex: Int
    /// `viewCount[i]` = how many triangles picked candidate view `i`.
    /// Dense array of length (maxViewIndex+1), zeros for unused indices.
    let viewCount: [Int]

    var sentinelFraction: Double {
        total > 0 ? Double(sentinelCount) / Double(total) : 0
    }
    var realFraction: Double { 1.0 - sentinelFraction }

    var description: String {
        var s = "ChosenViewsReport\n"
        s += "  total triangles      = \(total)\n"
        s += "  sentinel (0xFFFF)    = \(sentinelCount)" +
             " (\(String(format: "%.1f", sentinelFraction * 100))%)\n"
        s += "  with real view       = \(total - sentinelCount)" +
             " (\(String(format: "%.1f", realFraction * 100))%)\n"
        s += "  max view index used  = \(maxViewIndex)\n"
        s += "  per-view triangle counts (non-zero only):\n"
        for (i, count) in viewCount.enumerated() where count > 0 {
            s += "    view \(i): \(count)\n"
        }
        return s
    }
}

enum BakeDiagnostics {

    /// Histogram of the `chosenViews` array produced by selectBestView.
    /// `viewCountHint` lets the caller pre-size the per-view bucket array
    /// (CandidateViewPool.frames.count is the right value).
    static func chosenViewsHistogram(
        _ chosenViews: [UInt16],
        viewCountHint: Int = 0
    ) -> ChosenViewsReport {
        var sentinel = 0
        var maxIdx = 0
        // Single pass for max-index first so we can size the bucket array.
        for v in chosenViews where v != .max && Int(v) > maxIdx {
            maxIdx = Int(v)
        }
        let bucketCount = max(maxIdx + 1, viewCountHint, 1)
        var buckets = [Int](repeating: 0, count: bucketCount)
        for v in chosenViews {
            if v == .max { sentinel += 1 }
            else { buckets[Int(v)] += 1 }
        }
        return ChosenViewsReport(
            total: chosenViews.count,
            sentinelCount: sentinel,
            maxViewIndex: maxIdx,
            viewCount: buckets
        )
    }

    /// Same, but reads the histogram directly from the chosen-views
    /// MTLBuffer to avoid an extra Swift array copy when called inside
    /// the bake.
    static func chosenViewsHistogram(
        buffer: MTLBuffer,
        triangleCount: Int,
        viewCountHint: Int = 0
    ) -> ChosenViewsReport {
        let ptr = buffer.contents().bindMemory(to: UInt16.self,
                                                capacity: triangleCount)
        var arr = [UInt16](repeating: .max, count: triangleCount)
        for i in 0..<triangleCount { arr[i] = ptr[i] }
        return chosenViewsHistogram(arr, viewCountHint: viewCountHint)
    }
}

// MARK: - Atlas brightness

struct AtlasBrightnessReport: CustomStringConvertible {
    let width: Int
    let height: Int
    /// Per-channel means in 0...1 range, sRGB-decoded approximated as
    /// linearised (gamma 2.2). Good enough for "is this all grey or not."
    let meanR: Double
    let meanG: Double
    let meanB: Double
    /// Per-channel std dev across all pixels.
    let stdR: Double
    let stdG: Double
    let stdB: Double
    /// Fraction of pixels whose all-channel RGB is within ±0.02 of
    /// (0.45, 0.45, 0.50) — the grey-fallback color hard-coded in
    /// `MeshAtlasBaker.swift:1032`. A high value here is the smoking gun
    /// for "kernel never sampled."
    let greyFallbackFraction: Double

    var description: String {
        let s1 = "AtlasBrightnessReport \(width)x\(height)\n"
        let s2 = "  mean RGB = (" +
                 "\(String(format: "%.3f", meanR)), " +
                 "\(String(format: "%.3f", meanG)), " +
                 "\(String(format: "%.3f", meanB)))\n"
        let s3 = "  std  RGB = (" +
                 "\(String(format: "%.3f", stdR)), " +
                 "\(String(format: "%.3f", stdG)), " +
                 "\(String(format: "%.3f", stdB)))\n"
        let s4 = "  grey-fallback fraction = " +
                 "\(String(format: "%.3f", greyFallbackFraction))" +
                 " (warn if >0.5)\n"
        return s1 + s2 + s3 + s4
    }
}

extension BakeDiagnostics {

    /// Compute brightness stats from a UIImage atlas — accepts the
    /// `BakedChunk.atlas` already produced by `MeshAtlasBaker.bake`.
    /// Sub-samples to keep the work cheap even on a 4K atlas (~16M
    /// pixels); a 256×256 grid is plenty of signal for "is it grey."
    static func atlasBrightnessStats(_ image: UIImage) -> AtlasBrightnessReport? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width
        let h = cg.height
        let stride = 16            // sub-sample every 16th pixel each axis
        let samplesX = max(1, w / stride)
        let samplesY = max(1, h / stride)

        // Render the CGImage into a small known-format RGBA buffer once;
        // then iterate pixels in plain Swift.
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = samplesX * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * samplesY)
        let bitmapInfo: UInt32 =
            CGBitmapInfo.byteOrder32Big.rawValue |
            CGImageAlphaInfo.premultipliedLast.rawValue   // → RGBA
        let drewOK: Bool = pixels.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: samplesX, height: samplesY,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: cs,
                    bitmapInfo: bitmapInfo
                  ) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0,
                                     width: samplesX, height: samplesY))
            return true
        }
        guard drewOK else { return nil }

        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var sumR2 = 0.0, sumG2 = 0.0, sumB2 = 0.0
        var greyHits = 0
        let n = samplesX * samplesY
        for i in 0..<n {
            let r = Double(pixels[i * 4 + 0]) / 255.0
            let g = Double(pixels[i * 4 + 1]) / 255.0
            let b = Double(pixels[i * 4 + 2]) / 255.0
            sumR += r;  sumG += g;  sumB += b
            sumR2 += r * r;  sumG2 += g * g;  sumB2 += b * b
            // Grey fallback color in MeshAtlasBaker.swift:1032 is sRGB
            // (0.45, 0.45, 0.50). Tight tolerance; the kernel hard-codes
            // this exact value so the match should be near-exact.
            if abs(r - 0.45) < 0.02 &&
               abs(g - 0.45) < 0.02 &&
               abs(b - 0.50) < 0.02 {
                greyHits += 1
            }
        }
        let mR = sumR / Double(n)
        let mG = sumG / Double(n)
        let mB = sumB / Double(n)
        let vR = max(0, sumR2 / Double(n) - mR * mR)
        let vG = max(0, sumG2 / Double(n) - mG * mG)
        let vB = max(0, sumB2 / Double(n) - mB * mB)
        return AtlasBrightnessReport(
            width: w, height: h,
            meanR: mR, meanG: mG, meanB: mB,
            stdR: sqrt(vR), stdG: sqrt(vG), stdB: sqrt(vB),
            greyFallbackFraction: Double(greyHits) / Double(n)
        )
    }
}
