import Foundation
import SwiftUI

/// Lightweight license activation for the main app.
/// Shares ~/.screenrecorder/license.json with sr-mcp so activating
/// in either place works for both.
@MainActor
final class LicenseActivator: ObservableObject {
    static let shared = LicenseActivator()

    @Published var plan: String = "none"
    @Published var email: String = ""
    @Published var isActivated: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private let baseDir: URL
    private let licensePath: URL

    /// License server URL — override via SR_LICENSE_SERVER env var
    private var serverURL: String {
        ProcessInfo.processInfo.environment["SR_LICENSE_SERVER"]
            ?? "https://license.screenrecorder.dev"
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".screenrecorder")
        licensePath = baseDir.appendingPathComponent("license.json")

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        loadCached()
    }

    // MARK: - Activation

    /// Activate a license key by validating with the server.
    func activate(key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Please enter a license key"
            return
        }

        isLoading = true
        errorMessage = nil
        successMessage = nil

        do {
            let url = URL(string: "\(serverURL)/api/license/validate")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["key": trimmed])
            request.timeoutInterval = 15

            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(ValidationResponse.self, from: data)

            if response.valid {
                let cache = LicenseFile(
                    key: trimmed,
                    plan: response.plan,
                    email: response.email,
                    validatedAt: Date()
                )
                try saveCache(cache)
                plan = response.plan
                email = response.email
                isActivated = true
                successMessage = "License activated! Plan: \(response.plan.uppercased())"
            } else {
                errorMessage = "Invalid license: \(response.reason ?? "unknown")"
            }
        } catch {
            errorMessage = "Connection failed: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// Deactivate the local license.
    func deactivate() {
        try? FileManager.default.removeItem(at: licensePath)
        plan = "none"
        email = ""
        isActivated = false
        successMessage = nil
        errorMessage = nil
    }

    // MARK: - Cache

    private func loadCached() {
        guard let data = try? Data(contentsOf: licensePath),
              let cache = try? JSONDecoder().decode(LicenseFile.self, from: data)
        else { return }

        plan = cache.plan
        email = cache.email
        isActivated = true
    }

    private func saveCache(_ cache: LicenseFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cache)
        try data.write(to: licensePath, options: .atomic)
    }

    // MARK: - Models

    private struct LicenseFile: Codable {
        let key: String
        let plan: String
        let email: String
        let validatedAt: Date
    }

    private struct ValidationResponse: Codable {
        let valid: Bool
        let plan: String
        let email: String
        let reason: String?
    }
}
