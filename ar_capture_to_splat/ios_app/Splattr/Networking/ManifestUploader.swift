//
//  ManifestUploader.swift
//  Builds the multipart/form-data body for POST /upload exactly as
//  CAPTURE_PROTOCOL.md §2/§3 prescribe. AR-Layer 2 wires real values:
//    - per-frame pose + intrinsics + tracking_state from CapturedFrame
//    - depth + smoothed_depth multipart parts when present
//    - device descriptor + summary built by ARCaptureCoordinator
//
//  Frame JPEG and depth payloads are loaded lazily from disk (CapturedFrame
//  carries URLs — staged by FrameLogger) so memory stays bounded for long
//  sessions.
//

import Foundation
import UIKit

actor ManifestUploader {

    enum UploadError: LocalizedError {
        case notHTTP
        case server(status: Int, body: String)
        case decode(String)
        case fileRead(URL, Error)
        var errorDescription: String? {
            switch self {
            case .notHTTP: return "Bad response."
            case .server(let s, let b): return "Upload failed (HTTP \(s)). \(b)"
            case .decode(let s): return "Couldn't read laptop response: \(s)"
            case .fileRead(let u, let e): return "Couldn't read \(u.lastPathComponent): \(e.localizedDescription)"
            }
        }
    }

    let host: String
    init(host: String) { self.host = host }

    /// Build + POST.
    /// `device` and `summary` come from ARCaptureCoordinator; passing them in
    /// keeps the uploader pure (no AR imports) and lets fake-test scaffolds
    /// pass mocks if we ever revive them.
    func upload(
        descriptor: SessionDescriptor,
        sceneType: String,
        policy: CapturePolicy?,
        frames: [CapturedFrame],
        device: Manifest.Device,
        summary: Manifest.Summary,
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws -> UploadSummary {

        let manifest = Self.makeManifest(
            descriptor: descriptor,
            sceneType: sceneType,
            policy: policy,
            frames: frames,
            device: device,
            summary: summary
        )
        let manifestData = try JSONEncoder().encode(manifest)

        let boundary = "splattr-\(UUID().uuidString)"
        let body = try Self.buildBody(
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

    // MARK: - Manifest construction

    static func makeManifest(
        descriptor: SessionDescriptor,
        sceneType: String,
        policy: CapturePolicy?,
        frames: [CapturedFrame],
        device: Manifest.Device,
        summary: Manifest.Summary
    ) -> Manifest {
        let started = (frames.first?.timestamp ?? Date()).timeIntervalSince1970
        let ended = (frames.last?.timestamp ?? Date()).timeIntervalSince1970
        let mFrames: [Manifest.Frame] = frames.map { $0.toManifestFrame() }
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
            capture_policy: policy,
            frames: mFrames
        )
    }

    // MARK: - multipart body

    static func buildBody(
        boundary: String,
        sessionID: String,
        manifestData: Data,
        frames: [CapturedFrame]
    ) throws -> Data {
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

        for f in frames {
            // JPEG
            do {
                let bytes = try Data(contentsOf: f.jpegURL)
                append(headers: [
                    "Content-Disposition: form-data; name=\"frames\"; filename=\"\(f.manifestImagePath)\"",
                    "Content-Type: image/jpeg"
                ], payload: bytes)
            } catch {
                throw UploadError.fileRead(f.jpegURL, error)
            }
            // Depth (optional)
            if let url = f.depthURL, let path = f.manifestDepthPath {
                do {
                    let bytes = try Data(contentsOf: url)
                    append(headers: [
                        "Content-Disposition: form-data; name=\"depth\"; filename=\"\(path)\"",
                        "Content-Type: application/octet-stream"
                    ], payload: bytes)
                } catch {
                    throw UploadError.fileRead(url, error)
                }
            }
            // Smoothed depth (optional)
            if let url = f.smoothedDepthURL, let path = f.manifestSmoothedDepthPath {
                do {
                    let bytes = try Data(contentsOf: url)
                    append(headers: [
                        "Content-Disposition: form-data; name=\"depth_smoothed\"; filename=\"\(path)\"",
                        "Content-Type: application/octet-stream"
                    ], payload: bytes)
                } catch {
                    throw UploadError.fileRead(url, error)
                }
            }
        }

        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }
}
