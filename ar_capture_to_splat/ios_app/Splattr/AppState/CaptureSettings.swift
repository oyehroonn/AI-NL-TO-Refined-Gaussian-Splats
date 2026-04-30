//
//  CaptureSettings.swift
//  Persisted user-facing capture options. Right now: just the 60/30 Hz
//  preference. Defaults to 60 Hz on devices that support it.
//

import Foundation

enum CaptureCadence: Int, CaseIterable, Identifiable {
    case hz30 = 30
    case hz60 = 60
    var id: Int { rawValue }
    var label: String { "\(rawValue) Hz" }
}

enum CaptureSettings {

    private static let cadenceKey = "splattr.capture_cadence_hz_v1"

    static func cadence() -> CaptureCadence {
        let raw = UserDefaults.standard.integer(forKey: cadenceKey)
        if raw == 30 { return .hz30 }
        return .hz60     // default
    }

    static func setCadence(_ c: CaptureCadence) {
        UserDefaults.standard.set(c.rawValue, forKey: cadenceKey)
    }
}
