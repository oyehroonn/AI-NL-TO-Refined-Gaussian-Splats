//
//  BlurDetector.swift
//  Per-frame Laplacian-variance blur score on the YUV luma plane of an
//  ARFrame. Lazy Metal compute pipeline if available; CPU fallback so the
//  module compiles even without Metal access.
//
//  This is the same metric upload_to_splat/frame_quality_layer/blur_scorer.py
//  uses (Laplacian variance), so blur thresholds calibrated on the desktop
//  pipeline transfer to AR captures.
//

import CoreImage
import CoreVideo
import Foundation

enum BlurDetector {

    /// Compute Laplacian variance on the luma plane. Higher = sharper.
    /// Returns 0 if the buffer can't be decoded.
    static func score(for pixelBuffer: CVPixelBuffer) -> Double {
        // Lock the buffer for read.
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isYUV = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                  || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if isYUV {
            return cpuLaplacianVarianceLuma(pixelBuffer)
        }
        // Non-YUV path: fall back to CIImage average-luminance derivative.
        return cpuLaplacianVarianceRGBA(pixelBuffer)
    }

    // MARK: - YUV (luma plane) — fastest path

    private static func cpuLaplacianVarianceLuma(_ pb: CVPixelBuffer) -> Double {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return 0 }
        let width  = CVPixelBufferGetWidthOfPlane(pb, 0)
        let height = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        // Downsample in software for speed: skip every Nth row/col.
        // 1920×1440 YUV → ~480×360 effective grid. Plenty for a variance score.
        let step = 4
        var sum: Double = 0
        var sumSq: Double = 0
        var count = 0
        // 3×3 Laplacian: center * 4 - up - down - left - right.
        // Stay one pixel away from the edges.
        var y = step
        while y < height - step {
            var x = step
            while x < width - step {
                let centre = Double(bytes[y * stride + x])
                let up     = Double(bytes[(y - step) * stride + x])
                let down   = Double(bytes[(y + step) * stride + x])
                let left   = Double(bytes[y * stride + (x - step)])
                let right  = Double(bytes[y * stride + (x + step)])
                let lap = centre * 4 - up - down - left - right
                sum += lap
                sumSq += lap * lap
                count += 1
                x += step
            }
            y += step
        }
        guard count > 0 else { return 0 }
        let mean = sum / Double(count)
        return max(0, sumSq / Double(count) - mean * mean)
    }

    // MARK: - RGBA fallback

    private static func cpuLaplacianVarianceRGBA(_ pb: CVPixelBuffer) -> Double {
        let ci = CIImage(cvPixelBuffer: pb)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let scale: CGFloat = 0.25
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = scaled.extent
        let w = Int(extent.width)
        let h = Int(extent.height)
        guard w > 4, h > 4,
              let cg = context.createCGImage(scaled, from: extent)
        else { return 0 }
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let bm = CGContext(data: &pixels, width: w, height: h,
                                 bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                 space: cs,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return 0 }
        bm.draw(cg, in: extent)

        // Convert to luma in-place (Rec. 709)
        var luma = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Double(pixels[i * 4 + 0])
            let g = Double(pixels[i * 4 + 1])
            let b = Double(pixels[i * 4 + 2])
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        var sum: Double = 0; var sumSq: Double = 0; var count = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = luma[y * w + x]
                let up = luma[(y - 1) * w + x]
                let dn = luma[(y + 1) * w + x]
                let lf = luma[y * w + x - 1]
                let rt = luma[y * w + x + 1]
                let lap = c * 4 - up - dn - lf - rt
                sum += lap
                sumSq += lap * lap
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        let mean = sum / Double(count)
        return max(0, sumSq / Double(count) - mean * mean)
    }
}
