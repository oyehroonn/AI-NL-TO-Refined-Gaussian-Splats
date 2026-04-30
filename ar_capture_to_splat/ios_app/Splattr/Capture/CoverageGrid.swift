//
//  CoverageGrid.swift
//  AR-Layer 2 — coverage tracker.
//
//  72 cells: 8 yaw sectors × 3 distance bands × 3 pitch bands.
//  Each call to `observe(...)` increments the cell the camera is currently
//  pointing into. `coverageFraction` and `weakRegions()` drive the HUD and
//  feed manifest.summary.coverage_summary at session end.
//

import Foundation
import simd

struct CoverageGrid: Equatable {

    // 8 yaw × 3 distance × 3 pitch
    static let yawSectorCount: Int = 8
    static let distanceBandCount: Int = 3
    static let pitchBandCount: Int = 3
    static let cellCount: Int = yawSectorCount * distanceBandCount * pitchBandCount  // 72

    /// visit_count[y][d][p] — number of accepted frames that fell into this cell.
    private(set) var visits: [[[Int]]]

    /// Distance band edges (meters) — set from CapturePolicy at init.
    let nearM: Double
    let farM: Double

    /// Origin pose: the camera's first-frame world position. Used to anchor
    /// the radial frame so yaw stays meaningful.
    private(set) var originSet: Bool = false
    private(set) var originPosition: SIMD3<Float> = .zero
    private(set) var originHeading: Float = 0       // yaw of the first frame, radians

    init(nearMeters: Double, farMeters: Double) {
        self.nearM = nearMeters
        self.farM = farMeters
        self.visits = Array(
            repeating: Array(
                repeating: Array(repeating: 0, count: Self.pitchBandCount),
                count: Self.distanceBandCount
            ),
            count: Self.yawSectorCount
        )
    }

    /// Set the origin from the first accepted frame's camera transform.
    /// Subsequent observations are interpreted relative to this origin.
    mutating func setOrigin(cameraTransform: simd_float4x4) {
        originPosition = cameraTransform.translation
        originHeading = cameraTransform.yaw
        originSet = true
    }

    /// Record one accepted frame. Returns the cell index that was hit so
    /// callers can derive a per-frame `coverage_score` (e.g. higher when a
    /// fresh cell is added).
    @discardableResult
    mutating func observe(cameraTransform t: simd_float4x4) -> CellHit {
        if !originSet {
            setOrigin(cameraTransform: t)
        }
        let dx = t.translation.x - originPosition.x
        let dy = t.translation.y - originPosition.y
        let dz = t.translation.z - originPosition.z
        let horizontalDist = sqrt(dx * dx + dz * dz)

        let yawWorld = t.yaw
        let yawRel = normalizeAngle(yawWorld - originHeading)   // -π…π
        let yawSector = sectorIndex(forAngle: yawRel,
                                     sectorCount: Self.yawSectorCount)

        let distanceBand = bandIndex(forValue: Double(horizontalDist),
                                     edges: distanceEdges)
        let pitch = t.pitch                                      // -π/2…π/2
        let pitchBand = bandIndex(forValue: Double(pitch),
                                  edges: pitchEdges)

        let priorVisits = visits[yawSector][distanceBand][pitchBand]
        visits[yawSector][distanceBand][pitchBand] += 1
        return CellHit(
            yawSector: yawSector,
            distanceBand: distanceBand,
            pitchBand: pitchBand,
            wasFresh: priorVisits == 0
        )
    }

    /// Fraction of cells that have been visited at least once.
    var coverageFraction: Double {
        var covered = 0
        for y in 0..<Self.yawSectorCount {
            for d in 0..<Self.distanceBandCount {
                for p in 0..<Self.pitchBandCount {
                    if visits[y][d][p] > 0 { covered += 1 }
                }
            }
        }
        return Double(covered) / Double(Self.cellCount)
    }

    /// Number of distinct yaw sectors that have any cell visited.
    var coveredYawSectors: Int {
        var count = 0
        for y in 0..<Self.yawSectorCount {
            outer: for d in 0..<Self.distanceBandCount {
                for p in 0..<Self.pitchBandCount {
                    if visits[y][d][p] > 0 { count += 1; break outer }
                }
            }
        }
        return count
    }

    /// Compass-like region labels for the worst cells. Used by the upload
    /// summary to tell the laptop "the back wall is weak" in plain words.
    func weakRegions(top: Int = 5) -> [Manifest.Summary.CoverageSummary.WeakRegion] {
        struct Entry { let label: String; let visits: Int }
        var entries: [Entry] = []
        let yawLabels = ["front", "front-right", "right", "back-right",
                         "back", "back-left", "left", "front-left"]
        let distLabels = ["near", "mid", "far"]
        let pitchLabels = ["down", "mid", "up"]
        for y in 0..<Self.yawSectorCount {
            for d in 0..<Self.distanceBandCount {
                for p in 0..<Self.pitchBandCount {
                    let v = visits[y][d][p]
                    let label = "\(yawLabels[y]) · \(distLabels[d]) · \(pitchLabels[p])"
                    entries.append(Entry(label: label, visits: v))
                }
            }
        }
        entries.sort { $0.visits < $1.visits }       // weakest first
        return entries.prefix(top).map {
            // Score = 1 means well-covered, 0 means never visited.
            let denom = max(1, entries.last?.visits ?? 1)
            let score = Double($0.visits) / Double(denom)
            return .init(label: $0.label, score: score)
        }
    }

    // MARK: - Internal

    /// Distance bin edges. nearM and farM split [0, ∞) into 3 zones:
    /// near = [0, nearM); mid = [nearM, farM); far = [farM, ∞).
    private var distanceEdges: [Double] { [nearM, farM] }

    /// Pitch bin edges (radians). Three buckets: down (< -10°), mid (±10°), up (> +10°).
    private var pitchEdges: [Double] { [-10.0 * .pi / 180.0, 10.0 * .pi / 180.0] }

    private func sectorIndex(forAngle a: Float, sectorCount: Int) -> Int {
        // Map [-π, π] → [0, 2π) → sector
        let twoPi = Float.pi * 2
        let normalized = (a + twoPi).truncatingRemainder(dividingBy: twoPi)
        let sectorWidth = twoPi / Float(sectorCount)
        return min(Int(normalized / sectorWidth), sectorCount - 1)
    }

    private func bandIndex(forValue v: Double, edges: [Double]) -> Int {
        for (i, edge) in edges.enumerated() where v < edge {
            return i
        }
        return edges.count
    }
}

extension CoverageGrid {
    struct CellHit: Equatable {
        let yawSector: Int
        let distanceBand: Int
        let pitchBand: Int
        let wasFresh: Bool
    }
}

// MARK: - simd helpers

private func normalizeAngle(_ a: Float) -> Float {
    var x = a.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi }
    if x < -.pi { x += 2 * .pi }
    return x
}

extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
    /// Yaw (rotation around world +Y), radians.
    var yaw: Float {
        // ARKit's right-handed frame: -Z is the camera's forward axis.
        // The forward direction in world space = -columns.2 of the rotation matrix.
        let fx = -columns.2.x
        let fz = -columns.2.z
        return atan2(fx, fz)
    }
    /// Pitch (rotation around X), radians. Positive = looking up.
    var pitch: Float {
        // forward = -columns.2 → pitch = asin(forward.y)
        let fy = -columns.2.y
        return asin(max(-1, min(1, fy)))
    }
}
