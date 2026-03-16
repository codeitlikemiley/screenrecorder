import Foundation
import SwiftUI

/// Lightweight license activation for the main app.
/// Uses SharedDefaults (UserDefaults suite) so the license is instantly
/// available to sr CLI and sr-mcp without file sharing.
@MainActor
final class LicenseActivator: ObservableObject {
    static let shared = LicenseActivator()

    @Published var plan: String = "none"
    @Published var email: String = ""
    @Published var isActivated: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var successMessage: String?

    /// License server URL — resolved via SharedDefaults (env → UserDefaults → fallback)
    private var serverURL: String {
        SharedDefaults.licenseServerURL
    }

    private init() {
        // Migrate from legacy JSON if needed
        SharedDefaults.migrateFromJSON()
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
                SharedDefaults.saveLicense(
                    key: trimmed,
                    plan: response.plan,
                    email: response.email
                )
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
        SharedDefaults.removeLicense()
        plan = "none"
        email = ""
        isActivated = false
        successMessage = nil
        errorMessage = nil
    }

    // MARK: - Cache

    private func loadCached() {
        guard SharedDefaults.isActivated else { return }
        plan = SharedDefaults.licensePlan
        email = SharedDefaults.licenseEmail
        isActivated = true
    }

    // MARK: - Models

    private struct ValidationResponse: Codable {
        let valid: Bool
        let plan: String
        let email: String
        let reason: String?
    }
}
