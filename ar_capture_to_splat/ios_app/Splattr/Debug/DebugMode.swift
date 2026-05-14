//
//  DebugMode.swift
//  Splattr — Gold Tier Perfection (Phase A1, debug surface).
//
//  Central enable/disable flag for the on-phone debug overlay + log file
//  + artifact dumper. UserDefaults-backed so a debug session survives an
//  app restart on the test device.
//
//  Wiring contract:
//   - JoinView: hidden long-press on the "Connected" pill toggles enabled.
//   - CaptureView: when enabled, overlays DebugHUD and exposes a
//     "Share Debug Log" button.
//   - Everything else (DebugLog, ArtifactDumper, MetalDebug) keeps writing
//     unconditionally — the dump volume is tiny and we want past sessions
//     captured even if the user only flips the toggle after seeing a bug.
//     The toggle is purely a UI gate.
//
//  This file is intentionally tiny — the only persisted state in the
//  whole Debug module.
//

import Foundation
import SwiftUI

enum DebugMode {
    private static let enabledKey = "splattr.debug.enabled"

    /// Single source of truth. SwiftUI views read via `@AppStorage` directly;
    /// non-SwiftUI callers read here.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func toggle() {
        isEnabled.toggle()
    }
}

/// Convenience for SwiftUI views — same storage key as `DebugMode.isEnabled`.
/// Use `@AppStorage(DebugModeStorageKey.enabled) private var debugOn: Bool = false`
/// in any SwiftUI view that needs to reactively show / hide debug UI.
enum DebugModeStorageKey {
    static let enabled = "splattr.debug.enabled"
}
