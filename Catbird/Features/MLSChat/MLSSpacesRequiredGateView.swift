import AuthenticationServices
import CatbirdMLSCore
import SwiftUI

/// Explains why encrypted chat can't start yet, in plain words, when the account's PDS lacks
/// `com.atproto.space.*` or the OAuth session is missing Labyrinth Space/blob scopes
/// (`Spec §2`, `§5 I15`). Scope strings and server answers stay under Details for Support.
///
/// Standard Bluesky DMs remain active in Unified Chat even when MLS Spaces chat is unavailable.
struct MLSSpacesRequiredGateView: View {
  let eligibility: SpacesEligibilityStatus
  /// Requests the missing permissions. Receives the presenter for the server's consent
  /// page and returns what to show when the permissions were not granted.
  var onReauthorizeScopes: ((@escaping AuthorizationPresenter) async -> EncryptedChatPermissionFailure?)?
  var onRefreshCheck: (() async -> Void)?

  /// Shows a consent page and returns the URL it finished on.
  typealias AuthorizationPresenter = @MainActor (URL) async throws -> URL

  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @State private var isRefreshing = false
  @State private var isRequestingPermissions = false
  @State private var permissionFailure: EncryptedChatPermissionFailure?
  /// Set after Check Again finishes. The gate only stays on screen while the check still fails,
  /// so this is what tells the person their tap did something.
  @State private var checkedAgainWithoutChange = false

  private var headlineText: LocalizedStringResource {
    switch eligibility.reason {
    case .available:
      return LocalizedStringResource("Encrypted Chat Is Ready", comment: "Headline when encrypted chat can be used")
    case .pdsDoesNotSupportSpaces:
      return LocalizedStringResource("Encrypted Chat Isn’t Available", comment: "Headline when the account's server can't hold encrypted chat")
    case .missingOAuthScopes:
      return LocalizedStringResource("Allow Encrypted Chat", comment: "Headline when Catbird needs permission for encrypted chat")
    }
  }

  private var bodyText: String {
    switch eligibility.reason {
    case .available:
      return String(localized: "Encrypted chat is ready to use.", comment: "Encrypted chat gate body when available")
    case .pdsDoesNotSupportSpaces:
      return String(
        localized: "Your account’s server doesn’t support encrypted chat yet.",
        comment: "Encrypted chat gate body when the account's server lacks Spaces"
      )
    case .missingOAuthScopes:
      return String(
        localized: "Catbird needs your permission to keep your encrypted chats and their backup on your account’s server. You’ll confirm on your server’s page.",
        comment: "Encrypted chat gate body when permission is missing"
      )
    }
  }

  private var checkAgainResultText: String {
    switch eligibility.reason {
    case .missingOAuthScopes:
      return String(
        localized: "Still waiting for permission. Tap Allow Access to give it.",
        comment: "Shown after Check Again when permission is still missing"
      )
    case .pdsDoesNotSupportSpaces, .available:
      return String(
        localized: "Your server still doesn’t support encrypted chat.",
        comment: "Shown after Check Again when the server still lacks Spaces"
      )
    }
  }

  private var iconName: String {
    switch eligibility.reason {
    case .available:
      return "checkmark.shield.fill"
    case .pdsDoesNotSupportSpaces:
      return "externaldrive.badge.exclamationmark"
    case .missingOAuthScopes:
      return "lock.shield"
    }
  }

  private var missingScopes: [String] {
    if case .missingOAuthScopes(let scopes) = eligibility.reason {
      return scopes
    }
    return []
  }

  private var hasDetails: Bool {
    permissionFailure?.detail != nil || !missingScopes.isEmpty
  }

  var body: some View {
    VStack(spacing: 20) {
      Spacer(minLength: 16)

      Image(systemName: iconName)
        .font(.system(size: 44))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text(headlineText)
          .font(.title3)
          .bold()
          .multilineTextAlignment(.center)

        Text(bodyText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }

      if eligibility.blueskyDmsAvailable {
        Text("Your Bluesky messages still work as usual.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }

      HStack(spacing: 12) {
        if case .missingOAuthScopes = eligibility.reason, let onReauthorizeScopes {
          Button {
            self.requestPermissions(onReauthorizeScopes)
          } label: {
            if isRequestingPermissions {
              ProgressView()
                .controlSize(.small)
            } else {
              Text("Allow Access")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isRequestingPermissions || isRefreshing)
          .accessibilityIdentifier("mls-spaces-allow-access")
        }

        if let onRefreshCheck {
          Button {
            self.triggerRefresh(onRefreshCheck)
          } label: {
            if isRefreshing {
              ProgressView()
                .controlSize(.small)
            } else {
              Text("Check Again")
            }
          }
          .buttonStyle(.bordered)
          .disabled(isRefreshing || isRequestingPermissions)
          .accessibilityIdentifier("mls-spaces-check-again")
        }
      }

      if let permissionFailure {
        Text(permissionFailure.message)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
          .accessibilityIdentifier("mls-spaces-permission-failure")
      } else if checkedAgainWithoutChange {
        Text(checkAgainResultText)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
          .accessibilityIdentifier("mls-spaces-check-again-result")
      }

      if hasDetails {
        DisclosureGroup("Details for Support") {
          detailsContent
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 440, alignment: .leading)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("mls-spaces-details")
      }

      Spacer(minLength: 16)
    }
    .accessibilityIdentifier("mls-spaces-required-gate")
  }

  @ViewBuilder
  private var detailsContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let detail = permissionFailure?.detail {
        Text("Server answer")
          .font(.caption)
          .bold()
        Text(verbatim: detail)
          .font(.caption2.monospaced())
          .textSelection(.enabled)
      }
      if !missingScopes.isEmpty {
        Text("Permissions requested")
          .font(.caption)
          .bold()
        ForEach(missingScopes, id: \.self) { scope in
          Text(verbatim: scope)
            .font(.caption2.monospaced())
            .textSelection(.enabled)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 6)
  }

  private func requestPermissions(
    _ action: @escaping (@escaping AuthorizationPresenter) async -> EncryptedChatPermissionFailure?
  ) {
    isRequestingPermissions = true
    permissionFailure = nil
    checkedAgainWithoutChange = false
    Task { @MainActor in
      let failure = await action { authURL in
        try await self.presentConsent(authURL)
      }
      self.permissionFailure = failure
      self.isRequestingPermissions = false
    }
  }

  @MainActor
  private func presentConsent(_ authURL: URL) async throws -> URL {
    if #available(iOS 17.4, macOS 14.4, *) {
      return try await webAuthenticationSession.authenticate(
        using: authURL,
        callback: .https(host: "catbird.blue", path: "/oauth/permission-callback"),
        preferredBrowserSession: .shared,
        additionalHeaderFields: [:]
      )
    } else {
      return try await webAuthenticationSession.authenticate(
        using: authURL,
        callbackURLScheme: "catbird",
        preferredBrowserSession: .shared
      )
    }
  }

  private func triggerRefresh(_ action: @escaping () async -> Void) {
    isRefreshing = true
    permissionFailure = nil
    checkedAgainWithoutChange = false
    Task { @MainActor in
      await action()
      self.isRefreshing = false
      self.checkedAgainWithoutChange = true
    }
  }
}
