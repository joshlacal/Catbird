import Foundation
import Observation
import SwiftUI

// MARK: - Community Standards

/// Tracks each account's one-time agreement to Catbird's Terms of Service and Bluesky's
/// Community Guidelines, which must be accepted before the account can view or post content.
@MainActor
@Observable
final class CommunityStandards {
  static let shared = CommunityStandards()

  static let communityGuidelinesURL = URL(string: "https://bsky.social/about/support/community-guidelines")!

  static var termsOfServiceURL: URL {
    LegalConfig.termsOfServiceURL ?? URL(string: "https://catbird.blue/terms")!
  }

  /// Short notice shown under the sign-in buttons, with tappable links.
  static var signInFootnote: AttributedString {
    let markdown = "By continuing, you agree to Catbird’s [Terms of Service](\(termsOfServiceURL.absoluteString)) "
      + "and Bluesky’s [Community Guidelines](\(communityGuidelinesURL.absoluteString)). "
      + "There’s zero tolerance for objectionable content or abusive users."
    return (try? AttributedString(markdown: markdown))
      ?? AttributedString("By continuing, you agree to Catbird’s Terms of Service and Bluesky’s Community Guidelines. There’s zero tolerance for objectionable content or abusive users.")
  }

  private static let agreementKeyPrefix = "communityStandards.agreed.v1."

  private let defaults: UserDefaults
  /// Bumped on every change so SwiftUI re-reads the stored agreement.
  private var revision = 0

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func requiresAgreement(for did: String) -> Bool {
    _ = revision
    if isBypassedForTesting { return false }
    return !defaults.bool(forKey: Self.agreementKeyPrefix + did)
  }

  func recordAgreement(for did: String) {
    defaults.set(true, forKey: Self.agreementKeyPrefix + did)
    revision += 1
  }

  /// Automated UI and end-to-end runs in developer builds skip the agreement screen.
  private var isBypassedForTesting: Bool {
    #if DEBUG
    AppStateManager.shared.isE2EMode
      || ProcessInfo.processInfo.arguments.contains("--skip-community-standards")
    #else
    false
    #endif
  }
}

// MARK: - Agreement View

/// Shown once per account after sign-in or sign-up, before any posts are visible.
struct CommunityStandardsAgreementView: View {
  let appState: AppState
  @Environment(AppStateManager.self) private var appStateManager
  @Environment(\.colorScheme) private var colorScheme
  @State private var isSigningOut = false

  private var signedInHandle: String? {
    appState.currentUserProfile?.handle.description
      ?? appStateManager.authentication.getCachedProfileData(for: appState.userDID)?.handle
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          Image(systemName: "hand.raised.fill")
            .font(.largeTitle)
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity)
            .padding(.top, 32)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 8) {
            Text("Community Standards")
              .appFont(AppTextRole.title1)
              .fontWeight(.bold)
              .accessibilityAddTraits(.isHeader)

            Text("Catbird shows posts, replies, and messages from people across Bluesky. Before you continue, please agree to these standards.")
              .appFont(AppTextRole.body)
              .foregroundStyle(Color.secondary)
          }

          VStack(alignment: .leading, spacing: 20) {
            standardRow(
              systemImage: "nosign",
              title: "Zero Tolerance",
              detail: "There’s no place on Catbird for objectionable content or abusive users, including harassment, hate speech, threats, and content that exploits minors."
            )
            standardRow(
              systemImage: "flag.fill",
              title: "Report and Block",
              detail: "You can report posts and accounts, and block or mute anyone, from the More menu on any post or profile."
            )
            standardRow(
              systemImage: "checkmark.shield.fill",
              title: "Enforcement",
              detail: "Reports are reviewed by Bluesky’s moderators. Content and accounts that break these rules can be hidden or removed."
            )
          }

          VStack(alignment: .leading, spacing: 12) {
            Link(destination: CommunityStandards.termsOfServiceURL) {
              Label("Catbird Terms of Service", systemImage: "doc.text")
                .appFont(AppTextRole.body)
            }
            Link(destination: CommunityStandards.communityGuidelinesURL) {
              Label("Bluesky Community Guidelines", systemImage: "person.3")
                .appFont(AppTextRole.body)
            }
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
      }

      VStack(spacing: 12) {
        Button {
          CommunityStandards.shared.recordAgreement(for: appState.userDID)
        } label: {
          Text("Agree and Continue")
            .appFont(AppTextRole.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSigningOut)
        .accessibilityIdentifier("communityStandards.agree")

        Button {
          isSigningOut = true
          Task { @MainActor in
            await appStateManager.logout(isManual: true)
          }
        } label: {
          Text("Sign Out")
            .appFont(AppTextRole.body)
            .frame(maxWidth: .infinity)
        }
        .disabled(isSigningOut)

        if let signedInHandle {
          Text("Signed in as @\(signedInHandle)")
            .appFont(AppTextRole.caption)
            .foregroundStyle(Color.secondary)
        }
      }
      .frame(maxWidth: 560)
      .padding(.horizontal, 24)
      .padding(.top, 12)
      .padding(.bottom, 16)
      .frame(maxWidth: .infinity)
      .background(.bar)
    }
    .background(
      Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme)
        .ignoresSafeArea()
    )
  }

  private func standardRow(systemImage: String, title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 16) {
      Image(systemName: systemImage)
        .font(.title3)
        .foregroundStyle(Color.accentColor)
        .frame(width: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .appFont(AppTextRole.headline)
        Text(detail)
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(Color.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
