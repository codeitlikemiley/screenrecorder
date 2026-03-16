import Foundation

/// Shared UserDefaults suite for cross-process license data.
/// Used by ScreenRecorder.app, sr CLI, and sr-mcp server.
///
/// Stores data at ~/Library/Preferences/com.codeitlikemiley.screenrecorder.shared.plist
/// Works without sandboxing or App Group entitlements.
enum SharedDefaults {
    static let suiteName = "com.codeitlikemiley.screenrecorder.shared"
    static let suite = UserDefaults(suiteName: suiteName)!

    enum Keys {
        static let licenseKey = "license_key"
        static let licensePlan = "license_plan"
        static let licenseServerURL = "license_server_url"
        static let licenseEmail = "license_email"
        static let licenseValidatedAt = "license_validated_at"
    }

    // MARK: - Read

    static var licenseKey: String? {
        suite.string(forKey: Keys.licenseKey)
    }

    static var licensePlan: String {
        suite.string(forKey: Keys.licensePlan) ?? "none"
    }

    static var licenseEmail: String {
        suite.string(forKey: Keys.licenseEmail) ?? ""
    }

    static var licenseValidatedAt: Date? {
        suite.object(forKey: Keys.licenseValidatedAt) as? Date
    }

    static var isActivated: Bool {
        licenseKey != nil
    }

    /// License server URL — checks env var (CLI), then UserDefaults (GUI), then fallback
    static var licenseServerURL: String {
        // CLI binaries can use env var
        if let env = ProcessInfo.processInfo.environment["SR_LICENSE_SERVER"], !env.isEmpty {
            return env
        }
        // GUI app stores it in UserDefaults (set via Settings or build.sh)
        if let stored = suite.string(forKey: Keys.licenseServerURL), !stored.isEmpty {
            return stored
        }
        // Production fallback
        return "https://license.screenrecorder.dev"
    }

    static func setLicenseServerURL(_ url: String) {
        if url.isEmpty {
            suite.removeObject(forKey: Keys.licenseServerURL)
        } else {
            suite.set(url, forKey: Keys.licenseServerURL)
        }
        suite.synchronize()
    }

    // MARK: - Write

    static func saveLicense(key: String, plan: String, email: String) {
        suite.set(key, forKey: Keys.licenseKey)
        suite.set(plan, forKey: Keys.licensePlan)
        suite.set(email, forKey: Keys.licenseEmail)
        suite.set(Date(), forKey: Keys.licenseValidatedAt)
        suite.synchronize()
    }

    static func updatePlan(_ plan: String) {
        suite.set(plan, forKey: Keys.licensePlan)
        suite.set(Date(), forKey: Keys.licenseValidatedAt)
        suite.synchronize()
    }

    static func removeLicense() {
        suite.removeObject(forKey: Keys.licenseKey)
        suite.removeObject(forKey: Keys.licensePlan)
        suite.removeObject(forKey: Keys.licenseEmail)
        suite.removeObject(forKey: Keys.licenseValidatedAt)
        suite.synchronize()
    }

    // MARK: - Migration from legacy license.json

    /// Migrates license data from ~/.screenrecorder/license.json to UserDefaults suite.
    /// Removes the old file after successful migration.
    static func migrateFromJSON() {
        guard licenseKey == nil else { return } // Already have data

        let home = FileManager.default.homeDirectoryForCurrentUser
        let jsonPath = home
            .appendingPathComponent(".screenrecorder")
            .appendingPathComponent("license.json")

        guard let data = try? Data(contentsOf: jsonPath),
              let json = try? JSONDecoder().decode(LegacyLicense.self, from: data)
        else { return }

        saveLicense(key: json.key, plan: json.plan, email: json.email)
        try? FileManager.default.removeItem(at: jsonPath)

        fputs("Migrated license from license.json to UserDefaults suite\n", stderr)
    }

    private struct LegacyLicense: Codable {
        let key: String
        let plan: String
        let email: String
        let validatedAt: Date?
    }
}
