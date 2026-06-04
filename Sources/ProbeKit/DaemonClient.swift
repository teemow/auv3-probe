import Foundation

// DaemonClient is the app's single HTTP client to mcp-midi-controller's LAN
// receiver (mcp-midi-controller repo, internal/auv3receiver + internal/aumreceiver).
// Both halves of the app talk to the same host, so they share one client and one
// host-parsing path rather than duplicating it:
//
//   Audio units (AUv3, internal/auv3receiver):
//     POST /auv3-probe              — one audio unit's AudioUnitDetails
//     POST /auv3-probe/diagnostics  — the full scan report (incl. failures)
//   AUM sessions (.aumproj, internal/aumreceiver):
//     POST   /aum-session?name=<file> — upload one .aumproj's raw bytes
//     GET    /aum-session             — manifest of files the receiver can return
//     GET    /aum-session/{file}      — one file's raw bytes (to write into AUM)
//     DELETE /aum-session/{file}      — remove one staged file (controller-side)
//     DELETE /aum-session             — clear all staged files (controller-side)
//   Audio tap (AUv3 effect, internal/auv3receiver):
//     WS   /audio-stream            — live downsampled PCM + features (ProbeAudioTap)
//   Shared:
//     GET  /healthz                 — connectivity test, run first
//
// These paths/JSON shapes mirror the Go receivers' wire contract exactly (see
// internal/aumreceiver/receiver.go). The session ferry is optional: the app
// reads and inspects .aumproj/.aum_midimap on-device (AUMSessionParser), and only
// uses these endpoints to hand files to / pull files from mcp-midi-controller.
// Uploads/downloads move the exact bytes (no JSON re-encoding).
//
// Lives in ProbeKit so the ProbeAudioTap extension reuses the same host parsing
// (its `webSocketURL(path:)` builds the streaming endpoint from the same host).

public enum DaemonError: LocalizedError {
    case badHost(String)
    case notOK(Int, String)
    case healthzFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .badHost(let h):
            return "could not parse host \"\(h)\" (try host:7800)"
        case .notOK(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "mcp-midi-controller returned HTTP \(code)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        case .healthzFailed(let code):
            return "healthz returned HTTP \(code)"
        }
    }
}

public struct DaemonClient {
    public let baseURL: URL

    /// The daemon's default LAN bind port (`-listen :7800`).
    public static let defaultPort = 7800

    /// Sessions can be multiple MB, so file transfers get a generous timeout;
    /// the small JSON calls (audio-unit POST, manifest, healthz) stay snappy.
    public static let transferTimeout: TimeInterval = 120

    /// RFC3339 formatter used to ship a file's original modified time on upload,
    /// matching `time.RFC3339` on the receiver.
    public static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Build a client from a user-entered `host`, `host:port`, or full URL.
    /// Defaults to the `http` scheme and port 7800 when omitted. No endpoint is
    /// ever committed — the host is always supplied at runtime.
    public init?(host rawHost: String) {
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

    /// The WebSocket URL for a given path on the same host (e.g. `audio-stream`),
    /// translating `http`/`https` to `ws`/`wss`. Used by ProbeAudioTap to stream
    /// to the same receiver the app's host bar points at.
    public func webSocketURL(path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme {
        case "https": components.scheme = "wss"
        default: components.scheme = "ws"
        }
        components.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
    }

    // MARK: - Shared

    /// Hit `GET /healthz`; succeeds on any 2xx response.
    public func healthz() async throws {
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
    public func sendAudioUnit(_ details: AudioUnitDetails) async throws -> AudioUnitUploadResult {
        let data = try await postJSON(path: "auv3-probe", body: details.encoded())
        return try JSONDecoder().decode(AudioUnitUploadResult.self, from: data)
    }

    /// `POST /auv3-probe/diagnostics` with the full scan report (incl. failures).
    public func sendReport(_ report: ScanReport) async throws -> DiagnosticsResult {
        let data = try await postJSON(path: "auv3-probe/diagnostics", body: report.encoded())
        return try JSONDecoder().decode(DiagnosticsResult.self, from: data)
    }

    // MARK: - AUM sessions (.aumproj)

    /// `POST /aum-session?name=<filename>` with the verbatim `.aumproj` bytes
    /// (`application/octet-stream`, no JSON re-encoding). The receiver derives a
    /// staging id from the `name` query. The optional `modified` date is sent so
    /// the receiver can preserve the file's original timestamp (keeping device and
    /// controller rows showing the same date). Returns the decoded summary.
    public func uploadAUMSession(data: Data, filename: String, modified: Date? = nil) async throws -> AUMSessionSummary {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("aum-session"),
            resolvingAgainstBaseURL: false
        )
        var items = [URLQueryItem(name: "name", value: filename)]
        if let modified = modified {
            items.append(URLQueryItem(name: "modified", value: Self.rfc3339.string(from: modified)))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw DaemonError.badHost(baseURL.absoluteString) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = DaemonClient.transferTimeout
        request.httpBody = data
        let body = try await perform(request)
        return try JSONDecoder().decode(AUMSessionSummary.self, from: body)
    }

    /// `GET /aum-session` — the manifest of files mcp-midi-controller can return,
    /// mapped to the app's UI entries.
    public func listAUMSessions() async throws -> [AUMSessionEntry] {
        var request = URLRequest(url: baseURL.appendingPathComponent("aum-session"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let body = try await perform(request)
        let manifest = try JSONDecoder().decode(AUMSessionManifest.self, from: body)
        return manifest.sessions.map(\.asEntry)
    }

    /// `GET /aum-session/{file}` — the verbatim file bytes plus the filename the
    /// receiver advertises via `Content-Disposition` (falling back to `file`).
    /// The returned bytes are written into AUM unchanged.
    public func downloadAUMSession(filename: String) async throws -> (data: Data, filename: String) {
        let url = baseURL.appendingPathComponent("aum-session").appendingPathComponent(filename)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = DaemonClient.transferTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw DaemonError.notOK(code, String(data: data, encoding: .utf8) ?? "")
        }
        let resolved = Self.filename(from: http) ?? filename
        return (data, resolved)
    }

    /// `DELETE /aum-session/{file}` — remove one staged file from
    /// mcp-midi-controller (controller-side only; never touches the iPad).
    public func deleteAUMSession(filename: String) async throws {
        let url = baseURL.appendingPathComponent("aum-session").appendingPathComponent(filename)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        _ = try await perform(request)
    }

    /// `DELETE /aum-session` — clear every staged file from mcp-midi-controller.
    public func deleteAllAUMSessions() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("aum-session"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        _ = try await perform(request)
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
public struct AudioUnitUploadResult: Decodable {
    public let id: String
    public let name: String
    public let params: Int
    public let writable: Int
    public let staged: String
}
