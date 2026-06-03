import Foundation
import SwiftUI
import UniformTypeIdentifiers

// ProbeSender ships data to the auv3-probe LAN receiver in the main repo:
//   POST /auv3-probe              — one plugin's ProbeDump
//   POST /auv3-probe/diagnostics  — the full run report (incl. failures)
//   GET  /healthz                 — connectivity test, run first
// When the receiver is unreachable, ProbeJSONDocument backs a Save-to-Files
// fallback so a dump can be transferred manually.

/// The receiver's JSON reply to a successful POST /auv3-probe.
struct ProbeSendResult: Decodable {
    let id: String
    let name: String
    let params: Int
    let writable: Int
    let staged: String
}

enum SenderError: LocalizedError {
    case badHost(String)
    case notOK(Int, String)
    case healthzFailed(Int)

    var errorDescription: String? {
        switch self {
        case .badHost(let h):
            return "could not parse host \"\(h)\" (try host:7800)"
        case .notOK(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "receiver returned HTTP \(code)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        case .healthzFailed(let code):
            return "healthz returned HTTP \(code)"
        }
    }
}

struct ProbeSender {
    let baseURL: URL

    /// The receiver's default LAN bind port (`cmd/auv3-probe -listen :7800`).
    static let defaultPort = 7800

    /// Build a sender from a user-entered `host`, `host:port`, or full URL.
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
            components.port = ProbeSender.defaultPort
        }
        components.path = ""
        guard let url = components.url else { return nil }
        self.baseURL = url
    }

    /// Hit `GET /healthz`; succeeds on any 2xx response.
    func healthz() async throws {
        let url = baseURL.appendingPathComponent("healthz")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw SenderError.healthzFailed(code)
        }
    }

    /// `POST /auv3-probe` with the encoded dump; returns the receiver's summary.
    func send(_ dump: ProbeDump) async throws -> ProbeSendResult {
        let data = try await post(path: "auv3-probe", body: dump.encoded())
        return try JSONDecoder().decode(ProbeSendResult.self, from: data)
    }

    /// `POST /auv3-probe/diagnostics` with the full run report (incl. failures);
    /// returns the receiver's per-status tally.
    func sendReport(_ report: ProbeReport) async throws -> DiagnosticsResult {
        let data = try await post(path: "auv3-probe/diagnostics", body: report.encoded())
        return try JSONDecoder().decode(DiagnosticsResult.self, from: data)
    }

    private func post(path: String, body: Data) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw SenderError.notOK(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}

/// A JSON `FileDocument` for the Save-to-Files fallback (`.fileExporter`).
/// Backs the manual-transfer path when the receiver is unreachable.
struct ProbeJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(dump: ProbeDump) throws {
        self.data = try dump.encoded()
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
