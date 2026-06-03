import Foundation

// DaemonClient is the app's single HTTP client to the companion daemon's LAN
// receiver (the mcp-midi-controller repo, internal/auv3receiver). Both halves of
// the app talk to the same daemon, so they share one client and one host-parsing
// path rather than duplicating it:
//
//   Audio units (AUv3):
//     POST /auv3-probe              — one audio unit's AudioUnitDetails
//     POST /auv3-probe/diagnostics  — the full scan report (incl. failures)
//   AUM sessions (.aumproj):
//     POST /aum-session             — upload one .aumproj's raw bytes
//     GET  /aum-sessions            — manifest of files the daemon can return
//     GET  /aum-session/{id}        — one file's raw bytes (to write into AUM)
//     GET  /aum-session/{id}/map    — the parsed AUMSessionMap (for inspection)
//   Shared:
//     GET  /healthz                 — connectivity test, run first
//
// (The audio-unit endpoint paths still say "auv3-probe" — that is the daemon's
// wire contract, unchanged. The Swift side names the concept directly.)
//
// Session uploads/downloads move the exact .aumproj bytes (no JSON re-encoding):
// the app has no project parser, so re-serializing would corrupt a format it does
// not model. All structured understanding of a project comes from the daemon's
// /map endpoint, which the Go internal/aum library produces.

enum DaemonError: LocalizedError {
    case badHost(String)
    case notOK(Int, String)
    case healthzFailed(Int)

    var errorDescription: String? {
        switch self {
        case .badHost(let h):
            return "could not parse host \"\(h)\" (try host:7800)"
        case .notOK(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "daemon returned HTTP \(code)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        case .healthzFailed(let code):
            return "healthz returned HTTP \(code)"
        }
    }
}

struct DaemonClient {
    let baseURL: URL

    /// The daemon's default LAN bind port (`-listen :7800`).
    static let defaultPort = 7800

    /// Sessions can be multiple MB, so file transfers get a generous timeout;
    /// the small JSON calls (audio-unit POST, manifest, healthz) stay snappy.
    static let transferTimeout: TimeInterval = 120

    /// Build a client from a user-entered `host`, `host:port`, or full URL.
    /// Defaults to the `http` scheme and port 7800 when omitted. No endpoint is
    /// ever committed — the host is always supplied at runtime.
    init?(host rawHost: String) {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme), components.host != nil else {
            return nil
        }
        if components.port == nil {
            components.port = DaemonClient.defaultPort
        }
        components.path = ""
        guard let url = components.url else { return nil }
        self.baseURL = url
    }

    // MARK: - Shared

    /// Hit `GET /healthz`; succeeds on any 2xx response.
    func healthz() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("healthz"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw DaemonError.healthzFailed(code)
        }
    }

    // MARK: - Audio units (AUv3)

    /// `POST /auv3-probe` with the encoded details; returns the daemon's summary.
    func sendAudioUnit(_ details: AudioUnitDetails) async throws -> AudioUnitUploadResult {
        let data = try await postJSON(path: "auv3-probe", body: details.encoded())
        return try JSONDecoder().decode(AudioUnitUploadResult.self, from: data)
    }

    /// `POST /auv3-probe/diagnostics` with the full scan report (incl. failures).
    func sendReport(_ report: ScanReport) async throws -> DiagnosticsResult {
        let data = try await postJSON(path: "auv3-probe/diagnostics", body: report.encoded())
        return try JSONDecoder().decode(DiagnosticsResult.self, from: data)
    }

    // MARK: - AUM sessions (.aumproj)

    /// `POST /aum-session` with the verbatim `.aumproj` bytes. The filename rides
    /// in `X-AUM-Filename` and the body is `application/octet-stream` — no JSON
    /// re-encoding of the project. Returns the daemon's decoded summary.
    func uploadAUMSession(data: Data, filename: String) async throws -> AUMSessionSummary {
        var request = URLRequest(url: baseURL.appendingPathComponent("aum-session"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(filename, forHTTPHeaderField: "X-AUM-Filename")
        request.timeoutInterval = DaemonClient.transferTimeout
        request.httpBody = data
        let body = try await perform(request)
        return try JSONDecoder().decode(AUMSessionSummary.self, from: body)
    }

    /// `GET /aum-sessions` — the manifest of files the daemon can return.
    func listAUMSessions() async throws -> [AUMSessionEntry] {
        var request = URLRequest(url: baseURL.appendingPathComponent("aum-sessions"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let body = try await perform(request)
        return try JSONDecoder().decode([AUMSessionEntry].self, from: body)
    }

    /// `GET /aum-session/{id}` — the verbatim file bytes plus the filename the
    /// daemon advertises via `Content-Disposition` (falling back to `<id>`). The
    /// returned bytes are written into AUM unchanged.
    func downloadAUMSession(id: String) async throws -> (Data, String) {
        let url = baseURL.appendingPathComponent("aum-session").appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = DaemonClient.transferTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw DaemonError.notOK(code, String(data: data, encoding: .utf8) ?? "")
        }
        let filename = Self.filename(from: http) ?? id
        return (data, filename)
    }

    /// `GET /aum-session/{id}/map` — the parsed, JSON AUMSessionMap the daemon's
    /// internal/aum library produces from the stored project. This is what the
    /// in-app inspector renders; the app itself never parses the plist.
    func fetchAUMSessionMap(id: String) async throws -> AUMSessionMap {
        let url = baseURL.appendingPathComponent("aum-session")
            .appendingPathComponent(id)
            .appendingPathComponent("map")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = DaemonClient.transferTimeout
        let body = try await perform(request)
        return try JSONDecoder().decode(AUMSessionMap.self, from: body)
    }

    // MARK: - Plumbing

    private func postJSON(path: String, body: Data) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = body
        return try await perform(request)
    }

    /// Send `request`, returning the body on a 2xx or throwing `DaemonError`.
    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw DaemonError.notOK(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Extract a `filename="..."` (or bare `filename=...`) from a
    /// `Content-Disposition` header, if present.
    private static func filename(from response: HTTPURLResponse?) -> String? {
        guard let disposition = response?.value(forHTTPHeaderField: "Content-Disposition") else {
            return nil
        }
        for part in disposition.split(separator: ";") {
            let token = part.trimmingCharacters(in: .whitespaces)
            guard token.lowercased().hasPrefix("filename=") else { continue }
            var value = String(token.dropFirst("filename=".count))
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

// MARK: - Audio-unit upload DTO

/// The daemon's JSON reply to a successful `POST /auv3-probe`.
/// (`DiagnosticsResult`, the reply to the diagnostics POST, lives in
/// AudioUnitDetails.swift alongside the scan-report types it summarizes.)
struct AudioUnitUploadResult: Decodable {
    let id: String
    let name: String
    let params: Int
    let writable: Int
    let staged: String
}
