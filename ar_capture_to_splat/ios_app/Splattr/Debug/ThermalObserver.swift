//
//  ThermalObserver.swift
//  Splattr — Gold Tier Perfection (Phase A1, debug surface).
//
//  Wraps ProcessInfo.thermalState + the change notification so DebugHUD
//  has a single observable to bind to, and DebugLog gets a `.thermal`
//  record every time the state moves. Answers "did my phone get hot
//  during the bake" without needing a USB-C tether.
//
//  Why a dedicated observable: ProcessInfo's notification is NotificationCenter-
//  based and not @Published. Bridging once here keeps the SwiftUI HUD
//  ergonomic.
//

import Combine
import Foundation
import UIKit

@MainActor
final class ThermalObserver: ObservableObject {

    static let shared = ThermalObserver()

    @Published private(set) var state: ProcessInfo.ThermalState

    private var token: NSObjectProtocol?

    private init() {
        self.state = ProcessInfo.processInfo.thermalState
        DebugLog.shared.thermal("thermal",
                                "initial state \(state.label)")

        token = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let newState = ProcessInfo.processInfo.thermalState
            Task { @MainActor in
                guard let self = self else { return }
                let old = self.state
                guard newState != old else { return }
                self.state = newState
                DebugLog.shared.thermal(
                    "thermal",
                    "\(old.label) → \(newState.label)"
                )
            }
        }
    }

    deinit {
        if let token = token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

extension ProcessInfo.ThermalState {
    /// Stable string used in logs + HUD pill text.
    var label: String {
        switch self {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Pill color used by DebugHUD. SwiftUI Color, no asset catalog dep.
    var swiftUIColor: (r: Double, g: Double, b: Double) {
        switch self {
        case .nominal:  return (0.40, 0.85, 0.50)   // green
        case .fair:     return (0.95, 0.78, 0.30)   // amber
        case .serious:  return (0.95, 0.50, 0.25)   // orange
        case .critical: return (0.95, 0.30, 0.30)   // red
        @unknown default: return (0.65, 0.65, 0.65)
        }
    }
}
