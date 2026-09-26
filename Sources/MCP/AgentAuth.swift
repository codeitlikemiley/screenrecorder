import Foundation

/// Shared-secret + timeout helpers for talking to the app's agent server.
/// Kept in sync with `AgentServer` (token file path and header name).
enum AgentAuth {
    static let header = "X-SR-Token"

    static var tokenFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".screenrecorder", isDirectory: true)
            .appendingPathComponent("agent-token")
    }

    /// The token the running app wrote at launch, or nil if the app isn't running.
    static func token() -> String? {
        guard let data = try? Data(contentsOf: tokenFileURL),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// Client-side timeout for an RPC. Long-running methods (shell commands, sleeps, slow typing)
    /// get enough headroom that the client doesn't give up while the app is still working.
    static func timeout(method: String, params: [String: Any]?) -> TimeInterval {
        func number(_ key: String) -> Double? {
            if let d = params?[key] as? Double { return d }
            if let i = params?[key] as? Int { return Double(i) }
            return nil
        }
        var seconds: TimeInterval = 30
        if let t = number("timeout") { seconds = max(seconds, t + 10) }
        if method == "sleep", let ms = number("ms") ?? number("duration") { seconds = max(seconds, ms / 1000 + 10) }
        if let text = params?["text"] as? String {
            let interval = number("interval_ms") ?? 50
            seconds = max(seconds, Double(text.count) * interval / 1000 + 10)
        }
        return seconds
    }
}
