import AuthenticationServices
import CatbirdMLSCore
import SwiftUI

/// Clear Spaces-required explanation shown when the account's PDS lacks `com.atproto.space.*`
/// or the OAuth session is missing Labyrinth Space/blob scopes (`Spec §2`, `§5 I15`).
///
/// Standard Bluesky DMs remain active in Unified Chat even when MLS Spaces chat is unavailable.
struct MLSSpacesRequiredGateView: View {
  let eligibility: SpacesEligibilityStatus
  /// Requests the missing permissions. Receives the presenter for the server's consent
  /// page and returns text to show when the permissions were not granted.
  var onReauthorizeScopes: ((@escaping AuthorizationPresenter) async -> String?)?
  var onRefreshCheck: (() async -> Void)?

  /// Shows a consent page and returns the URL it finished on.
  typealias AuthorizationPresenter = @MainActor (URL) async throws -> URL

  @Environment(\.webAuthenticationSession) private var webAuthenticationSession
  @State private var isRefreshing = false
  @State private var isRequestingPermissions = false
  @State private var permissionFailure: String?

  private var headlineText: String {
    switch eligibility.reason {
    case .available:
      return "ATProto Spaces Ready"
    case .pdsDoesNotSupportSpaces:
      return "ATProto Spaces Required"
    case .missingOAuthScopes:
      return "Spaces Permissions Needed"
    }
  }

  private var iconName: String {
    switch eligibility.reason {
    case .available:
      return "checkmark.shield.fill"
    case .pdsDoesNotSupportSpaces:
      return "externaldrive.badge.exclamationmark"
    case .missingOAuthScopes:
      return "key.radiowaves.forward.fill"
    }
  }

  private var missingScopes: [String] {
    if case .missingOAuthScopes(let scopes) = eligibility.reason {
      return scopes
    }
    return []
  }

  var body: some View {
    VStack(spacing: 20) {
      Spacer(minLength: 16)

      Image(systemName: iconName)
        .font(.system(size: 44))
        .foregroundStyle(.orange)
        .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text(headlineText)
          .font(.title3)
          .bold()
          .multilineTextAlignment(.center)

        Text(eligibility.userMessage)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }

      if !missingScopes.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Missing OAuth Scopes")
            .font(.caption)
            .bold()
            .foregroundStyle(.secondary)

          ForEach(missingScopes, id: \.self) { scope in
            Label(scope, systemImage: "lock.circle")
              .font(.caption2.monospaced())
              .foregroundStyle(.primary)
          }
        }
        .padding(12)
        .frame(maxWidth: 440, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        .padding(.horizontal, 24)
      }

      if eligibility.blueskyDmsAvailable {
        Label(
          "Standard Bluesky DMs remain active in your inbox.",
          systemImage: "bubble.left.and.bubble.right.fill"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
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
              Label("Grant Spaces Permissions", systemImage: "person.badge.key.fill")
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isRequestingPermissions)
        }

        if let onRefreshCheck {
          Button {
            self.triggerRefresh(onRefreshCheck)
          } label: {
            if isRefreshing {
              ProgressView()
                .controlSize(.small)
            } else {
              Label("Check Again", systemImage: "arrow.clockwise")
            }
          }
          .buttonStyle(.bordered)
          .disabled(isRefreshing)
        }
      }

      if let permissionFailure {
        Text(permissionFailure)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
          .accessibilityIdentifier("mls-spaces-permission-failure")
      }

      Spacer(minLength: 16)
    }
    .accessibilityIdentifier("mls-spaces-required-gate")
  }

  private func requestPermissions(
    _ action: @escaping (@escaping AuthorizationPresenter) async -> String?
  ) {
    isRequestingPermissions = true
    permissionFailure = nil
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
    Task { @MainActor in
      await action()
      self.isRefreshing = false
    }
  }
}
