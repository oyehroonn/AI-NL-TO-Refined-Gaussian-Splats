//
//  ManifestUploader.swift
//  Builds the multipart/form-data body for POST /upload exactly as
//  CAPTURE_PROTOCOL.md §2 prescribes: session_id (text), manifest
//  (manifest.json), and one `frames` part per frame using filename
//  "frames/frame_<N>.jpg" (the laptop server treats the manifest's
//  image_path values as authoritative).
//

import Foundation
import UIKit

actor ManifestUploader {

    enum UploadError: LocalizedError {
        case notHTTP
        case server(status: Int, body: String)
        case decode(String)
        var errorDescription: String? {
            switch self {
            case .notHTTP: return "Bad response."
            case .server(let s, let b): return "Upload failed (HTTP \(s)). \(b)"
            case .decode(let s): return "Couldn't read laptop response: \(s)"
            }
        }
    }

    let host: String

    init(host: String) { self.host = host }

    func upload(
        descriptor: SessionDescriptor,
        sceneType: String,
        frames: [CapturedFrame],
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> UploadSummary {
        let manifest = Self.makeManifest(descriptor: descriptor,
                                         sceneType: sceneType,
                                         frames: frames)
        let manifestData = try JSONEncoder().encode(manifest)

        let boundary = "splattr-\(UUID().uuidString)"
        let body = Self.buildBody(
            boundary: boundary,
            sessionID: descriptor.session_id,
            manifestData: manifestData,
            frames: frames
        )

        var req = URLRequest(url: URL(string: "http://\(host)/upload")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")
        req.setValue(String(body.count), forHTTPHeaderField: "Content-Length")

        progress(0.05)
        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
        progress(0.95)

        guard let http = response as? HTTPURLResponse else { throw UploadError.notHTTP }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UploadError.server(status: http.statusCode, body: body)
        }

        struct ServerOK: Decodable {
            let ok: Bool
            let run_id: String
            let frames_received: Int
            let depth_received: Int?
            let tracking_state_breakdown: [String: Int]?
        }
        let parsed: ServerOK
        do {
            parsed = try JSONDecoder().decode(ServerOK.self, from: data)
        } catch {
            throw UploadError.decode(error.localizedDescription)
        }
        progress(1.0)
        return UploadSummary(
            runID: parsed.run_id,
            framesReceived: parsed.frames_received,
            depthReceived: parsed.depth_received ?? 0,
            trackingBreakdown: parsed.tracking_state_breakdown ?? [:]
        )
    }

    // MARK: - manifest construction

    static func makeManifest(
        descriptor: SessionDescriptor,
        sceneType: String,
        frames: [CapturedFrame]
    ) -> Manifest {
        let now = Date().timeIntervalSince1970
        let started = (frames.first?.timestamp ?? Date()).timeIntervalSince1970
        let ended = (frames.last?.timestamp ?? Date()).timeIntervalSince1970

        let identityIntr = { (w: Int, h: Int) -> [[Double]] in
            let f = Double(max(w, h))
            return [[f, 0, Double(w)/2.0],
                    [0, f, Double(h)/2.0],
                    [0, 0, 1]]
        }
        let stubPose = { (i: Int) -> [[Double]] in
            let tz = 0.05 * Double(i)
            return [[1, 0, 0, 0],
                    [0, 1, 0, 0],
                    [0, 0, 1, tz],
                    [0, 0, 0, 1]]
        }

        let mFrames: [Manifest.Frame] = frames.enumerated().map { (i, f) in
            Manifest.Frame(
                frame_id: i,
                timestamp: f.timestamp.timeIntervalSince1970,
                image_path: "frames/\(filename(for: i))",
                camera_transform_world: stubPose(i),
                camera_intrinsics: identityIntr(f.width, f.height),
                image_width: f.width,
                image_height: f.height,
                tracking_state: "normal",
                tracking_reason: nil,
                world_mapping_status: "extending",
                raw_feature_points_count: 1500 + i,
                has_scene_depth: false,
                scene_depth_path: nil,
                smoothed_scene_depth_path: nil,
                pose_quality_score: 0.9,
                blur_score: 150.0,
                coverage_score: 0.6,
                accepted_for_training: true
            )
        }

        let device = Manifest.Device(
            model: UIDevice.current.modelIdentifier,
            os: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            lidar_supported: false,
            scene_reconstruction_supported: false,
            ar_world_tracking_configuration: Manifest.ARConfig(
                video_format: .init(
                    width: frames.first?.width ?? 1920,
                    height: frames.first?.height ?? 1080,
                    fps: 30
                ),
                frame_semantics: [],
                plane_detection: [],
                scene_reconstruction: "none"
            )
        )
        let summary = Manifest.Summary(
            frames_captured: frames.count,
            frames_kept: frames.count,
            duration_seconds: max(0, ended - started),
            tracking_state_breakdown: ["normal": frames.count],
            world_mapping_status_breakdown: ["extending": frames.count],
            coverage_summary: .init(covered_fraction: 0.6, weak_regions: []),
            preview_run: false,
            enhance_run: false
        )
        return Manifest(
            schema_version: 1,
            session_id: descriptor.session_id,
            run_id: descriptor.run_id,
            video_name: descriptor.displayVideoName,
            scene_type: sceneType,
            started_at_unix: started,
            ended_at_unix: ended,
            device: device,
            summary: summary,
            frames: mFrames
        )
    }

    static func filename(for index: Int) -> String {
        String(format: "frame_%06d.jpg", index)
    }

    // MARK: - multipart body

    static func buildBody(
        boundary: String,
        sessionID: String,
        manifestData: Data,
        frames: [CapturedFrame]
    ) -> Data {
        var data = Data()
        let crlf = "\r\n".data(using: .utf8)!
        let bnd = "--\(boundary)".data(using: .utf8)!

        func append(headers: [String], payload: Data) {
            data.append(bnd); data.append(crlf)
            for h in headers {
                data.append((h + "\r\n").data(using: .utf8)!)
            }
            data.append(crlf)
            data.append(payload)
            data.append(crlf)
        }

        append(headers: [
            "Content-Disposition: form-data; name=\"session_id\""
        ], payload: sessionID.data(using: .utf8)!)

        append(headers: [
            "Content-Disposition: form-data; name=\"manifest\"; filename=\"manifest.json\"",
            "Content-Type: application/json"
        ], payload: manifestData)

        for (i, f) in frames.enumerated() {
            append(headers: [
                "Content-Disposition: form-data; name=\"frames\"; filename=\"frames/\(filename(for: i))\"",
                "Content-Type: image/jpeg"
            ], payload: f.jpegData)
        }

        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }
}

// MARK: - device model identifier

private extension UIDevice {
    /// e.g. "iPhone16,1" — what the AR/Splat pipeline cares about.
    var modelIdentifier: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        let id = mirror.children.compactMap { ch -> String? in
            guard let v = ch.value as? Int8, v != 0 else { return nil }
            return String(UnicodeScalar(UInt8(v)))
        }.joined()
        return id.isEmpty ? UIDevice.current.model : id
    }
}
