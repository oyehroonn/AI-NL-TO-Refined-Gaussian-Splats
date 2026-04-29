//
//  SessionDescriptor.swift
//  Mirrors GET /session JSON (CAPTURE_PROTOCOL.md §2).
//

import Foundation

struct SessionDescriptor: Codable, Equatable, Hashable {
    let session_id: String
    let run_id: String
    let video_name: String?
    let scene_type_default: String?
    let protocol_version: Int
    let expires_at_unix: Int

    var displayVideoName: String { video_name ?? "Capture" }
    var displaySceneType: String { scene_type_default ?? "room" }
}
