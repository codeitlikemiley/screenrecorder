import Foundation

/// Manages license key validation and local rate limiting.
/// License data cached at ~/.screenrecorder/license.json
/// Usage data tracked at ~/.screenrecorder/usage.json
final class LicenseManager {
    static let shared = LicenseManager()

    private let baseDir: URL
    private let licensePath: URL
    private let usagePath: URL

    private var cachedLicense: LicenseCache?
    private var cachedUsage: UsageTracker?

    /// Default license server URL — override via SR_LICENSE_SERVER env var
    var licenseServerURL: String {
        ProcessInfo.processInfo.environment["SR_LICENSE_SERVER"]
            ?? "https://license.screenrecorder.dev"
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".screenrecorder")
        licensePath = baseDir.appendingPathComponent("license.json")
        usagePath = baseDir.appendingPathComponent("usage.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // Load cached data
        cachedLicense = loadJSON(from: licensePath)
        cachedUsage = loadJSON(from: usagePath)
    }

    // MARK: - License Activation

    /// Activate a license key by validating with the server
    func activate(key: String) async throws -> LicenseCache {
        let url = URL(string: "\(licenseServerURL)/api/license/validate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["key": key])

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(LicenseValidationResponse.self, from: data)

        guard response.valid else {
            throw LicenseError.invalid(response.reason ?? "unknown")
        }

        let cache = LicenseCache(
            key: key,
            plan: response.plan,
            email: response.email,
            validatedAt: Date()
        )

        cachedLicense = cache
        saveJSON(cache, to: licensePath)

        // Reset usage on activation
        let usage = UsageTracker(date: todayString(), callCount: 0)
        cachedUsage = usage
        saveJSON(usage, to: usagePath)

        return cache
    }

    /// Deactivate the local license
    func deactivate() {
        cachedLicense = nil
        try? FileManager.default.removeItem(at: licensePath)
    }

    // MARK: - Rate Limiting

    /// Check if a tool call is allowed. Returns true if allowed.
    func checkRateLimit() -> Bool {
        guard let license = cachedLicense else {
            return false // No license activated
        }

        // Pro users: unlimited
        if license.plan == "pro" {
            return true
        }

        // Free users: 100 calls/day
        var usage = cachedUsage ?? UsageTracker(date: todayString(), callCount: 0)

        // Reset if new day
        if usage.date != todayString() {
            usage = UsageTracker(date: todayString(), callCount: 0)
        }

        return usage.callCount < 100
    }

    /// Record a tool call
    func recordCall() {
        var usage = cachedUsage ?? UsageTracker(date: todayString(), callCount: 0)

        if usage.date != todayString() {
            usage = UsageTracker(date: todayString(), callCount: 0)
        }

        usage.callCount += 1
        cachedUsage = usage
        saveJSON(usage, to: usagePath)
    }

    /// Get current usage info
    var currentUsage: (used: Int, limit: Int, plan: String) {
        let plan = cachedLicense?.plan ?? "none"
        let limit = plan == "pro" ? -1 : 100
        let usage = cachedUsage ?? UsageTracker(date: todayString(), callCount: 0)
        let used = usage.date == todayString() ? usage.callCount : 0
        return (used, limit, plan)
    }

    /// Whether a valid license is cached
    var isActivated: Bool { cachedLicense != nil }

    /// The cached license info
    var license: LicenseCache? { cachedLicense }

    // MARK: - Helpers

    private func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    private func loadJSON<T: Decodable>(from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func saveJSON<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Models

struct LicenseCache: Codable {
    let key: String
    let plan: String
    let email: String
    let validatedAt: Date
}

struct UsageTracker: Codable {
    var date: String
    var callCount: Int
}

struct LicenseValidationResponse: Codable {
    let valid: Bool
    let plan: String
    let email: String
    let reason: String?
}

enum LicenseError: Error, LocalizedError {
    case invalid(String)
    case rateLimited
    case notActivated

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return "Invalid license: \(reason)"
        case .rateLimited: return "Rate limit exceeded (100 calls/day on free plan). Upgrade at https://screenrecorder.dev"
        case .notActivated: return "No license activated. Run: sr activate YOUR-KEY"
        }
    }
}
