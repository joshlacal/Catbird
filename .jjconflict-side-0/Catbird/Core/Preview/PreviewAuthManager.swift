import Foundation
import OSLog
import Petrel

/// Manages authentication for SwiftUI previews using credentials from PreviewSecrets.xcconfig.
///
/// Uses the same legacy (password) auth path as E2E tests — no OAuth flow needed.
/// Credentials are read from the xcconfig file at the project root.
@MainActor
final class PreviewAuthManager {
  static let shared = PreviewAuthManager()

  private let logger = Logger(subsystem: "blue.catbird", category: "PreviewAuth")
  private(set) var cachedClient: ATProtoClient?
  private(set) var cachedUserDID: String?
  private var authenticationTask: Task<ATProtoClient?, Never>?
  private var _isConfigured: Bool?

  private init() {}

  // MARK: - Credential Reading

  /// Whether xcconfig credentials are present
  var isConfigured: Bool {
    if let cached = _isConfigured { return cached }
    let creds = readCredentials()
    let configured = creds != nil
    _isConfigured = configured
    return configured
  }

  /// Read credentials from PreviewSecrets.xcconfig at the project root
  private func readCredentials() -> (handle: String, appPassword: String)? {
    let xcconfigURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Preview/
      .deletingLastPathComponent()  // Core/
      .deletingLastPathComponent()  // Catbird/
      .deletingLastPathComponent()  // Catbird/ (project root)
      .appendingPathComponent("PreviewSecrets.xcconfig")

    guard let contents = try? String(contentsOf: xcconfigURL, encoding: .utf8) else {
      logger.debug("PreviewSecrets.xcconfig not found at \(xcconfigURL.path)")
      return nil
    }
    return parseXCConfig(contents)
  }

  /// Parse key=value pairs from xcconfig format
  private func parseXCConfig(_ contents: String) -> (handle: String, appPassword: String)? {
    var handle: String?
    var password: String?

    for line in contents.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("//") else { continue }

      let parts = trimmed.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }

      let key = parts[0].trimmingCharacters(in: .whitespaces)
      let value = parts[1].trimmingCharacters(in: .whitespaces)

      switch key {
      case "PREVIEW_HANDLE" where !value.isEmpty:
        handle = value
      case "PREVIEW_APP_PASSWORD" where !value.isEmpty:
        password = value
      default:
        break
      }
    }

    guard let h = handle, let p = password,
      h != "your-handle.bsky.social", !p.contains("xxxx")
    else {
      return nil
    }

    return (h, p)
  }

  // MARK: - Authentication

  /// Returns an authenticated ATProtoClient, creating one if needed.
  /// Uses in-process caching — only authenticates once per Xcode canvas session.
  func getClient() async -> ATProtoClient? {
    if let cached = cachedClient { return cached }

    // Coalesce concurrent auth requests
    if let existing = authenticationTask {
      return await existing.value
    }

    let task = Task<ATProtoClient?, Never> { @MainActor in
      guard let creds = readCredentials() else {
        logger.info("No preview credentials configured")
        return nil
      }

      logger.info("Authenticating preview client for: \(creds.handle)")

      do {
        let oauthConfig = OAuthConfiguration(
          clientId: "https://catbird.blue/oauth-client-metadata.json",
          redirectUri: "https://catbird.blue/oauth/callback",
          scope: "atproto transition:generic transition:chat.bsky"
        )

        let newClient = try await ATProtoClient(
          baseURL: URL(string: "https://bsky.social")!,
          oauthConfig: oauthConfig,
          namespace: "blue.catbird.preview",
          authMode: .legacy,
          userAgent: "Catbird/1.0-Preview"
        )

        let accountInfo = try await newClient.loginWithPassword(
          identifier: creds.handle,
          password: creds.appPassword
        )

        self.cachedClient = newClient
        self.cachedUserDID = accountInfo.did
        logger.info("Preview auth successful for DID: \(accountInfo.did)")
        return newClient
      } catch {
        logger.error("Preview auth failed: \(error.localizedDescription)")
        return nil
      }
    }

    authenticationTask = task
    let result = await task.value
    authenticationTask = nil
    return result
  }
}
