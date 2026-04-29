//
//  SessionClient.swift
//  GET /session, GET /tutorial-config. ATS is allowed for plain http via
//  Info.plist (NSAllowsArbitraryLoads = true) — necessary because the
//  laptop session server is http-only on the LAN.
//

import Foundation

struct SessionClient {
    /// "ip:port" — comes from the deep-link.
    let host: String

    var baseURL: URL { URL(string: "http://\(host)")! }

    func fetchSession() async throws -> SessionDescriptor {
        let url = baseURL.appendingPathComponent("session")
        let (data, response) = try await URLSession.shared.data(from: url)
        try checkOK(response: response, data: data, label: "GET /session")
        return try JSONDecoder().decode(SessionDescriptor.self, from: data)
    }

    func fetchTutorialConfig(sceneType: String) async throws -> TutorialConfig {
        var comp = URLComponents(url: baseURL.appendingPathComponent("tutorial-config"),
                                 resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "scene_type", value: sceneType)]
        let (data, response) = try await URLSession.shared.data(from: comp.url!)
        try checkOK(response: response, data: data, label: "GET /tutorial-config")
        return try JSONDecoder().decode(TutorialConfig.self, from: data)
    }

    private func checkOK(response: URLResponse, data: Data, label: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw NSError(domain: "Splattr.Net", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "\(label) failed: HTTP \(http.statusCode). \(body)"
            ])
        }
    }
}

struct TutorialConfig: Codable, Equatable {
    let scene_type: String
    let tips: [String]
    let fallback: Bool?
}
