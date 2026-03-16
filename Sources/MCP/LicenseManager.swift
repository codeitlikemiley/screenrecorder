import Foundation

/// Manages license key validation and local rate limiting.
/// License data stored in shared UserDefaults suite (accessible by all app binaries).
/// Usage data tracked at ~/.screenrecorder/usage.json (MCP-specific).
final class LicenseManager {
    static let shared = LicenseManager()

    /// Revalidation interval: 24 hours
    private let revalidationInterval: TimeInterval = 24 * 60 * 60
    /// Grace period when server is unreachable: 7 days
    private let gracePeriod: TimeInterval = 7 * 24 * 60 * 60

    /// Shared UserDefaults suite — same as the main app
    private let suiteName = "com.codeitlikemiley.screenrecorder.shared"
    private lazy var suite: UserDefaults = {
        UserDefaults(suiteName: suiteName)!
    }()

    private let baseDir: URL
    private let usagePath: URL

    private var cachedUsage: UsageTracker?
    private var isRevalidating = false

    /// License server URL — checks env var, then shared UserDefaults, then fallback
    var licenseServerURL: String {
        if let env = ProcessInfo.processInfo.environment["SR_LICENSE_SERVER"], !env.isEmpty {
            return env
        }
        if let stored = suite.string(forKey: "license_server_url"), !stored.isEmpty {
            return stored
        }
        return "https://license.screenrecorder.dev"
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".screenrecorder")
        usagePath = baseDir.appendingPathComponent("usage.json")

        // Create directory if needed (for usage.json)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // Migrate from legacy license.json if needed
        migrateFromJSON()

        // Load usage data
        cachedUsage = loadJSON(from: usagePath)
    }

    // MARK: - UserDefaults License Access

    private var storedKey: String? {
        suite.string(forKey: "license_key")
    }

    private var storedPlan: String {
        suite.string(forKey: "license_plan") ?? "none"
    }

    private var storedEmail: String {
        suite.string(forKey: "license_email") ?? ""
    }

    private var storedValidatedAt: Date? {
        suite.object(forKey: "license_validated_at") as? Date
    }

    private func saveLicense(key: String, plan: String, email: String) {
        suite.set(key, forKey: "license_key")
        suite.set(plan, forKey: "license_plan")
        suite.set(email, forKey: "license_email")
        suite.set(Date(), forKey: "license_validated_at")
        suite.synchronize()
    }

    private func updatePlan(_ plan: String) {
        suite.set(plan, forKey: "license_plan")
        suite.set(Date(), forKey: "license_validated_at")
        suite.synchronize()
    }

    private func removeLicense() {
        suite.removeObject(forKey: "license_key")
        suite.removeObject(forKey: "license_plan")
        suite.removeObject(forKey: "license_email")
        suite.removeObject(forKey: "license_validated_at")
        suite.synchronize()
    }

    // MARK: - Migration

    private func migrateFromJSON() {
        guard storedKey == nil else { return }

        let jsonPath = baseDir.appendingPathComponent("license.json")
        guard let data = try? Data(contentsOf: jsonPath),
              let legacy = try? JSONDecoder().decode(LicenseCache.self, from: data)
        else { return }

        saveLicense(key: legacy.key, plan: legacy.plan, email: legacy.email)
        try? FileManager.default.removeItem(at: jsonPath)
        fputs("Migrated license from license.json to UserDefaults suite\n", stderr)
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

        saveLicense(key: key, plan: response.plan, email: response.email)

        let cache = LicenseCache(
            key: key,
            plan: response.plan,
            email: response.email,
            validatedAt: Date()
        )

        // Reset usage on activation
        let usage = UsageTracker(date: todayString(), callCount: 0)
        cachedUsage = usage
        saveJSON(usage, to: usagePath)

        return cache
    }

    /// Deactivate the local license
    func deactivate() {
        removeLicense()
    }

    // MARK: - Revalidation

    /// Re-validate the cached license with the server if stale (>24h old).
    func revalidateIfNeeded() async {
        guard let key = storedKey, !isRevalidating else { return }

        let validatedAt = storedValidatedAt ?? Date.distantPast
        let age = Date().timeIntervalSince(validatedAt)
        guard age > revalidationInterval else { return }

        isRevalidating = true
        defer { isRevalidating = false }

        let currentPlan = storedPlan
        fputs("License cache is \(Int(age/3600))h old — revalidating...\n", stderr)

        do {
            let url = URL(string: "\(licenseServerURL)/api/license/validate")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["key": key])
            request.timeoutInterval = 10

            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(LicenseValidationResponse.self, from: data)

            if response.valid {
                saveLicense(key: key, plan: response.plan, email: response.email)
                if response.plan != currentPlan {
                    fputs("License plan changed: \(currentPlan) → \(response.plan)\n", stderr)
                } else {
                    fputs("License revalidated — plan: \(response.plan)\n", stderr)
                }
            } else {
                fputs("License no longer valid: \(response.reason ?? "unknown"). Deactivating.\n", stderr)
                deactivate()
            }
        } catch {
            fputs("Revalidation failed (\(error.localizedDescription)) — using cached plan\n", stderr)
            if age > gracePeriod {
                fputs("Grace period (7d) exceeded — downgrading to free\n", stderr)
                updatePlan("free")
            }
        }
    }

    // MARK: - Rate Limiting

    /// Check if a tool call is allowed. Revalidates first if needed.
    func checkRateLimit() async -> Bool {
        await revalidateIfNeeded()

        guard storedKey != nil else {
            return false // No license activated
        }

        // Pro users: unlimited
        if storedPlan == "pro" {
            return true
        }

        // Free users: 100 calls/day
        var usage = cachedUsage ?? UsageTracker(date: todayString(), callCount: 0)

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
        let plan = storedPlan
        let limit = plan == "pro" ? -1 : 100
        let usage = cachedUsage ?? UsageTracker(date: todayString(), callCount: 0)
        let used = usage.date == todayString() ? usage.callCount : 0
        return (used, limit, plan)
    }

    /// Whether a valid license is cached
    var isActivated: Bool { storedKey != nil }

    /// The cached license info
    var license: LicenseCache? {
        guard let key = storedKey else { return nil }
        return LicenseCache(
            key: key,
            plan: storedPlan,
            email: storedEmail,
            validatedAt: storedValidatedAt ?? Date()
        )
    }

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
