import CatbirdMLSCore
import SwiftUI

/// Clear Spaces-required explanation shown when the account's PDS lacks `com.atproto.space.*`
/// or the OAuth session is missing Labyrinth Space/blob scopes (`Spec §2`, `§5 I15`).
///
/// Standard Bluesky DMs remain active in Unified Chat even when MLS Spaces chat is unavailable.
struct MLSSpacesRequiredGateView: View {
  let eligibility: SpacesEligibilityStatus
  var onReauthorizeScopes: (() -> Void)?
  var onRefreshCheck: (() async -> Void)?

  @State private var isRefreshing = false

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
            onReauthorizeScopes()
          } label: {
            Label("Grant Spaces Permissions", systemImage: "person.badge.key.fill")
          }
          .buttonStyle(.borderedProminent)
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

      Spacer(minLength: 16)
    }
    .accessibilityIdentifier("mls-spaces-required-gate")
  }

  private func triggerRefresh(_ action: @escaping () async -> Void) {
    isRefreshing = true
    Task { @MainActor in
      await action()
      self.isRefreshing = false
    }
  }
}
