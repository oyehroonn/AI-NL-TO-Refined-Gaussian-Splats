//
//  ArtifactDumper.swift
//  Splattr — Gold Tier Perfection (Phase A1, debug surface).
//
//  Dumps any MTLTexture / MTLBuffer / UIImage to disk under
//  `FileManager.temporaryDirectory/splattr_artifacts/<session>/<tag>.png`.
//  The whole directory can be Share-Sheet'd off the device after a bake.
//
//  The point: every silent-grayscale bake to date died because we never
//  saw the intermediate state on Mac. Now we can:
//
//   * Dump each `CandidateViewPool.textureArray` slice as a PNG → proves
//     the camera frames actually arrived in the texture array as color
//     pixels and weren't zero-filled by a silent blit no-op.
//   * Dump the final atlas of each bake as a PNG → if it opens in
//     Preview as a colorful UV-unwrapped jumble, the kernel + sampler
//     are correct and the bug is downstream in the SCN material path.
//     If it opens as flat grey, the kernel never sampled real frames.
//   * Dump the `chosenViews` UInt16 buffer as text → tells us if FIX
//     A/B/C in selectBestView actually picked real view indices vs the
//     0xFFFF sentinel.
//
//  Storage layout:
//   tmp/splattr_artifacts/2026-05-14T18-31-07.412Z/
//     candidate_slice_000.png
//     candidate_slice_001.png
//     atlas_chunk_0.png
//     chosen_views.txt
//     manifest.txt           (one line per artifact written, with size)
//
//  Disk hygiene: we don't currently auto-clean older session folders.
//  iOS clears `temporaryDirectory` on its own when the device gets
//  low-storage notifications, which is acceptable for a debug-only
//  feature. If this becomes annoying we add a "Clear All Artifacts"
//  button to the debug HUD.
//

import CoreGraphics
import Foundation
import ImageIO
import Metal
import MobileCoreServices
import UIKit
import UniformTypeIdentifiers

enum ArtifactDumper {

    // MARK: - Session dir

    /// One directory per app launch — keeps a bug repro's dumps grouped.
    static let sessionDirectory: URL = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime,
                                    .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("splattr_artifacts", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }()

    // MARK: - MTLTexture → PNG

    /// Dump a 2D MTLTexture to `<sessionDir>/<tag>.png`. Returns the URL
    /// on success.
    @discardableResult
    static func dumpTexture(_ texture: MTLTexture,
                            as tag: String) -> URL? {
        guard texture.textureType == .type2D else {
            DebugLog.shared.warn(
                "artifact",
                "dumpTexture(\(tag)): unsupported textureType " +
                "\(texture.textureType.rawValue); use dumpTextureSlice instead"
            )
            return nil
        }
        return dumpTextureSlice(texture, slice: 0, as: tag)
    }

    /// Dump a single slice of a 2D-array (or single-slice 2D) texture.
    /// Use for the CandidateViewPool's `textureArray` slices.
    @discardableResult
    static func dumpTextureSlice(_ texture: MTLTexture,
                                  slice: Int,
                                  as tag: String) -> URL? {
        let w = texture.width
        let h = texture.height
        let bytesPerRow = w * 4
        let totalBytes = bytesPerRow * h
        var bytes = [UInt8](repeating: 0, count: totalBytes)
        let region = MTLRegionMake2D(0, 0, w, h)

        // .shared storage required for getBytes. If a future caller
        // wants to dump a .private texture, they must blit it to a
        // .shared scratch texture first.
        guard texture.storageMode == .shared else {
            DebugLog.shared.warn(
                "artifact",
                "dumpTexture(\(tag)): texture is .private; cannot getBytes"
            )
            return nil
        }
        texture.getBytes(&bytes,
                          bytesPerRow: bytesPerRow,
                          bytesPerImage: totalBytes,
                          from: region,
                          mipmapLevel: 0,
                          slice: slice)

        guard let image = bgraBytesToUIImage(
            bytes: bytes, width: w, height: h, bytesPerRow: bytesPerRow,
            isSRGB: texture.pixelFormat == .bgra8Unorm_srgb
        ) else {
            DebugLog.shared.warn(
                "artifact", "dumpTexture(\(tag)): CGImage build failed"
            )
            return nil
        }
        return dumpUIImage(image, as: tag)
    }

    /// Dump a UIImage as PNG. Use directly when you already have the
    /// image (e.g., one of `TexturedMeshRenderer.ExplorerSnapshot
    /// .textureImage`).
    @discardableResult
    static func dumpUIImage(_ image: UIImage, as tag: String) -> URL? {
        guard let png = image.pngData() else {
            DebugLog.shared.warn("artifact",
                                  "dumpUIImage(\(tag)): pngData failed")
            return nil
        }
        let url = sessionDirectory.appendingPathComponent("\(tag).png")
        do {
            try png.write(to: url, options: .atomic)
            appendManifest(line: "\(tag).png\t\(png.count)")
            DebugLog.shared.info(
                "artifact",
                "wrote \(tag).png (\(png.count) bytes)"
            )
            return url
        } catch {
            DebugLog.shared.error(
                "artifact",
                "write \(tag).png failed: \(error.localizedDescription)"
            )
            return nil
        }
    }

    // MARK: - MTLBuffer → text

    /// Dump a UInt16 buffer as CSV (one value per line). Used for
    /// `chosenViews` so we can grep / histogram on Mac. Keeps the dump
    /// small even for 200K triangles (~1.5 MB).
    @discardableResult
    static func dumpUInt16Buffer(_ buffer: MTLBuffer,
                                  count: Int,
                                  as tag: String) -> URL? {
        guard buffer.storageMode == .shared else {
            DebugLog.shared.warn(
                "artifact",
                "dumpUInt16Buffer(\(tag)): buffer is .private"
            )
            return nil
        }
        let ptr = buffer.contents().bindMemory(to: UInt16.self, capacity: count)
        var text = ""
        text.reserveCapacity(count * 6)
        for i in 0..<count {
            text.append(String(ptr[i]))
            text.append("\n")
        }
        let url = sessionDirectory.appendingPathComponent("\(tag).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            appendManifest(line: "\(tag).txt\t\(text.utf8.count)")
            DebugLog.shared.info(
                "artifact", "wrote \(tag).txt (\(count) values)"
            )
            return url
        } catch {
            DebugLog.shared.error(
                "artifact",
                "write \(tag).txt failed: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Write a one-shot text artifact — useful for human-readable
    /// summaries that don't have a structured shape (e.g., a histogram
    /// report).
    @discardableResult
    static func dumpText(_ text: String, as tag: String) -> URL? {
        let url = sessionDirectory.appendingPathComponent("\(tag).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            appendManifest(line: "\(tag).txt\t\(text.utf8.count)")
            return url
        } catch {
            DebugLog.shared.error(
                "artifact",
                "write \(tag).txt failed: \(error.localizedDescription)"
            )
            return nil
        }
    }

    // MARK: - Private helpers

    private static func appendManifest(line: String) {
        let url = sessionDirectory.appendingPathComponent("manifest.txt")
        let lineWithNewline = line + "\n"
        guard let data = lineWithNewline.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Build a UIImage from a tight BGRA byte buffer. Matches the
    /// pixel-layout choices used everywhere else in this project:
    /// 32-bit-little-endian + premultiplied-first → in-memory byte order
    /// is BGRA, which is what `MTLPixelFormat.bgra8Unorm[_srgb]` expects.
    private static func bgraBytesToUIImage(
        bytes: [UInt8],
        width: Int, height: Int, bytesPerRow: Int,
        isSRGB: Bool
    ) -> UIImage? {
        let cs = isSRGB
            ? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 =
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(
            data: NSData(bytes: bytes, length: bytes.count)
        ) else { return nil }
        guard let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
