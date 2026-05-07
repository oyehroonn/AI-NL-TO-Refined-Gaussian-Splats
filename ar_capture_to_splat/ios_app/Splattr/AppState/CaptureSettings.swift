//
//  CaptureSettings.swift
//  Persisted user-facing capture options:
//    - 60 vs 30 Hz cadence (existing)
//    - tier: Gold / Platinum / Max / On-Mobile (AR-Layer 2.5+)
//

import Foundation

enum CaptureCadence: Int, CaseIterable, Identifiable {
    case hz30 = 30
    case hz60 = 60
    var id: Int { rawValue }
    var label: String { "\(rawValue) Hz" }
}

/// User-selected quality tier — controls phone preview behavior. See
/// `IMPLEMENTATION_PLAN.md` for the full per-tier spec.
enum Tier: String, CaseIterable, Identifiable {
    /// Free baseline. Live LiDAR mesh in viewfinder, textured with the
    /// camera feed → "filling-in" effect during capture. Splat trains on
    /// laptop after upload.
    case gold
    /// Paid. Same Gold preview during capture + on-phone splat player
    /// after laptop training finishes.
    case platinum
    /// Top tier. Real-time hybrid — laptop trains, phone composites
    /// laptop-rendered novel views over the camera feed.
    case max
    /// Coming soon — true on-device 3DGS training (Beta).
    case onMobile

    var id: String { rawValue }

    /// Display headline (uppercased pill text).
    var displayName: String {
        switch self {
        case .gold:     return "GOLD"
        case .platinum: return "PLATINUM"
        case .max:      return "MAX"
        case .onMobile: return "ON-MOBILE"
        }
    }

    /// One-line user-facing description.
    var blurb: String {
        switch self {
        case .gold:
            return "Live mesh fills in the room with real-world texture as you scan. " +
                   "Splat trains on your Mac. Free."
        case .platinum:
            return "Gold preview + on-phone splat player after training. View, orbit, " +
                   "place in your room."
        case .max:
            return "Real splat trained on Mac, streamed back to your phone in real time. " +
                   "The Brush experience, in your viewfinder."
        case .onMobile:
            return "True Gaussian splat training on your iPhone. No Mac required."
        }
    }

    /// Right-side label (Free / Pro / Studio / Beta).
    var pill: String {
        switch self {
        case .gold:     return "FREE"
        case .platinum: return "PRO"
        case .max:      return "STUDIO"
        case .onMobile: return "BETA"
        }
    }

    /// Tiers gated as "coming soon". Selecting them is disabled in the UI.
    var isAvailable: Bool {
        switch self {
        case .gold:     return true
        case .platinum: return false       // Tier D — implementation pending
        case .max:      return false       // Tier B — implementation pending
        case .onMobile: return false       // Tier A — coming soon (Beta)
        }
    }
}

enum CaptureSettings {

    private static let cadenceKey = "splattr.capture_cadence_hz_v1"
    private static let tierKey = "splattr.tier_v1"

    // MARK: - Cadence

    static func cadence() -> CaptureCadence {
        let raw = UserDefaults.standard.integer(forKey: cadenceKey)
        if raw == 30 { return .hz30 }
        return .hz60     // default
    }

    static func setCadence(_ c: CaptureCadence) {
        UserDefaults.standard.set(c.rawValue, forKey: cadenceKey)
    }

    // MARK: - Tier

    /// User's currently-selected quality tier. Defaults to `.gold` for new
    /// installs. If a saved value is now disabled (e.g. we removed a tier
    /// in an update), falls back to `.gold`.
    static func tier() -> Tier {
        let raw = UserDefaults.standard.string(forKey: tierKey) ?? Tier.gold.rawValue
        let t = Tier(rawValue: raw) ?? .gold
        return t.isAvailable ? t : .gold
    }

    static func setTier(_ t: Tier) {
        UserDefaults.standard.set(t.rawValue, forKey: tierKey)
    }
}
