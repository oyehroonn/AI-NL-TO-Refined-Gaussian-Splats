//
//  Router.swift
//  One source of truth for which screen is showing. Driven by the deep-link
//  on cold launch and by user actions thereafter.
//

import Foundation
import SwiftUI

@MainActor
final class Router: ObservableObject {

    enum Screen: Equatable {
        case splash
        case join(SessionDescriptor, host: String)
        case tutorial(SessionDescriptor, host: String, mode: CaptureMode)
        case tutorialSkippedConfirm(SessionDescriptor, host: String, mode: CaptureMode)
        case capture(SessionDescriptor, host: String, policy: CapturePolicy)
        case upload(SessionDescriptor,
                    host: String,
                    policy: CapturePolicy,
                    frames: [CapturedFrame],
                    device: Manifest.Device,
                    summary: Manifest.Summary)
        case done(UploadSummary)
        case error(String)
    }

    @Published private(set) var screen: Screen = .splash
    /// Stable ID per screen used for view-transition animations.
    var screenID: String {
        switch screen {
        case .splash: return "splash"
        case .join: return "join"
        case .tutorial: return "tutorial"
        case .tutorialSkippedConfirm: return "tutorial_confirm"
        case .capture: return "capture"
        case .upload: return "upload"
        case .done: return "done"
        case .error: return "error"
        }
    }

    func handle(url: URL) {
        // Accept either claudesplat://join?... (deep-link) or
        // http://host:port/join?session=…&v=1 (universal-link-ish fallback).
        guard let parsed = ParsedJoinURL(url: url) else {
            screen = .error("Couldn't read the QR link. Try scanning again.")
            return
        }
        Task { await fetchSession(host: parsed.host, sessionID: parsed.sessionID) }
    }

    /// Called from JoinView's "Begin Capture" button.
    /// Routes through the tutorial, then ModeConfirmView, then capture.
    func startTutorial(descriptor: SessionDescriptor,
                       host: String,
                       mode: CaptureMode) {
        screen = .tutorial(descriptor, host: host, mode: mode)
    }

    /// Used when the user hits "Skip" on a mode they've completed before.
    func proceedToTutorialSkipped(descriptor: SessionDescriptor,
                                  host: String,
                                  mode: CaptureMode) {
        screen = .tutorialSkippedConfirm(descriptor, host: host, mode: mode)
    }

    /// Called from ModeConfirmView. The CapturePolicy is built there.
    func proceedToCapture(descriptor: SessionDescriptor,
                          host: String,
                          policy: CapturePolicy) {
        screen = .capture(descriptor, host: host, policy: policy)
    }

    func proceedToUpload(descriptor: SessionDescriptor,
                        host: String,
                        policy: CapturePolicy,
                        frames: [CapturedFrame],
                        device: Manifest.Device,
                        summary: Manifest.Summary) {
        screen = .upload(descriptor, host: host, policy: policy,
                         frames: frames, device: device, summary: summary)
    }

    func finished(summary: UploadSummary) {
        screen = .done(summary)
    }

    func fail(_ message: String) {
        screen = .error(message)
    }

    func reset() {
        screen = .splash
    }

    // MARK: - private

    private func fetchSession(host: String, sessionID: String) async {
        do {
            let client = SessionClient(host: host)
            let descriptor = try await client.fetchSession()
            guard descriptor.session_id == sessionID else {
                screen = .error("Session mismatch. Re-scan the laptop's QR.")
                return
            }
            screen = .join(descriptor, host: host)
        } catch {
            screen = .error("Couldn't reach the laptop session at \(host). \(error.localizedDescription)")
        }
    }
}

/// Parses both URL forms (custom scheme + http fallback) into the same shape.
struct ParsedJoinURL {
    let host: String   // "ip:port"
    let sessionID: String

    init?(url: URL) {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let session = comps.queryItems?.first(where: { $0.name == "session" })?.value,
              !session.isEmpty
        else { return nil }

        if url.scheme == "claudesplat" {
            // claudesplat://join?session=…&host=ip:port&v=1
            guard let host = comps.queryItems?.first(where: { $0.name == "host" })?.value,
                  !host.isEmpty
            else { return nil }
            self.host = host
            self.sessionID = session
        } else if url.scheme == "http" || url.scheme == "https" {
            // http://ip:port/join?session=…&v=1
            guard let h = comps.host else { return nil }
            let port = comps.port.map { ":\($0)" } ?? ""
            self.host = h + port
            self.sessionID = session
        } else {
            return nil
        }
    }
}
