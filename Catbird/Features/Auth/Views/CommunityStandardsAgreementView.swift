import Foundation
import SwiftUI

/// Policy links shown on the sign-in screen, and the agreement people accept
/// before they sign in or create an account.
enum CommunityStandards {
  static let communityGuidelinesURL = URL(string: "https://bsky.social/about/support/community-guidelines")!

  static var termsOfServiceURL: URL {
    LegalConfig.termsOfServiceURL ?? URL(string: "https://catbird.blue/terms")!
  }

  /// Raise this when the agreement's wording changes, so everyone accepts the new terms.
  static let agreementVersion = 1

  /// `UserDefaults` key holding the highest agreement version accepted on this device.
  static let acceptedAgreementVersionKey = "communityStandards.acceptedAgreementVersion"

  private static let accountAcceptancePrefix = "communityStandards.accountAcceptedVersion."
  private static let pendingAcceptanceVersionKey = "communityStandards.pendingAcceptanceVersion"
  private static let pendingAcceptanceDateKey = "communityStandards.pendingAcceptanceAt"
  /// Sign-up can finish in a browser after email verification and a relaunch.
  private static let pendingAcceptanceValidity: TimeInterval = 60 * 60

  /// Whether the account has accepted the current agreement version.
  static func hasAcceptedCurrentVersion(for accountDID: String, defaults: UserDefaults = .standard) -> Bool {
    defaults.integer(forKey: accountAcceptancePrefix + accountDID) >= agreementVersion
  }

  /// Records that the account accepted the current agreement version.
  static func recordAcceptance(for accountDID: String, defaults: UserDefaults = .standard) {
    defaults.set(agreementVersion, forKey: accountAcceptancePrefix + accountDID)
  }

  /// Records an agreement accepted on the sign-in screen, before the account is known.
  static func recordAcceptanceBeforeSignIn(defaults: UserDefaults = .standard) {
    defaults.set(agreementVersion, forKey: acceptedAgreementVersionKey)
    defaults.set(agreementVersion, forKey: pendingAcceptanceVersionKey)
    defaults.set(Date().timeIntervalSince1970, forKey: pendingAcceptanceDateKey)
  }

  /// Returns whether the current agreement was accepted on the sign-in screen recently,
  /// and clears that record so it applies to the one account that signs in next.
  static func consumeAcceptanceBeforeSignIn(defaults: UserDefaults = .standard) -> Bool {
    let version = defaults.integer(forKey: pendingAcceptanceVersionKey)
    let acceptedAt = defaults.double(forKey: pendingAcceptanceDateKey)
    defaults.removeObject(forKey: pendingAcceptanceVersionKey)
    defaults.removeObject(forKey: pendingAcceptanceDateKey)
    guard version >= agreementVersion, acceptedAt > 0 else { return false }
    return Date().timeIntervalSince1970 - acceptedAt < pendingAcceptanceValidity
  }
}

/// Asks for explicit agreement to the Terms of Service and Community Guidelines,
/// including zero tolerance for objectionable content and abusive users, before
/// someone signs in or creates an account, and from any signed-in account that
/// hasn't accepted the current version.
struct CommunityStandardsAgreementView: View {
  var declineTitle: LocalizedStringKey = "Cancel"
  let onAgree: () -> Void
  let onCancel: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("Catbird has zero tolerance for objectionable content and abusive users.")
            .appFont(AppTextRole.headline)

          Text("Posts, replies, messages and accounts that harass, threaten, exploit or abuse others are not allowed. Catbird's moderators review reports from Circles and encrypted chats, and Bluesky's moderation service reviews reports about public posts and accounts. Content that breaks these rules can be labeled or removed, and accounts that break them can be suspended.")
            .appFont(AppTextRole.body)

          Text("You can report any post, account or message, and block or mute anyone, from its menu.")
            .appFont(AppTextRole.body)

          VStack(alignment: .leading, spacing: 12) {
            Link("Terms of Service", destination: CommunityStandards.termsOfServiceURL)
              .accessibilityIdentifier("agreement.terms")
            Link("Community Guidelines", destination: CommunityStandards.communityGuidelinesURL)
              .accessibilityIdentifier("agreement.communityGuidelines")
          }
          .appFont(AppTextRole.body)

          Text("By tapping Agree, you accept the Terms of Service and Community Guidelines.")
            .appFont(AppTextRole.footnote)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
      }
      .safeAreaInset(edge: .bottom) {
        Button(action: onAgree) {
          Text("Agree")
            .appFont(AppTextRole.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .padding()
        .accessibilityIdentifier("agreement.agree")
      }
      .navigationTitle("Community Standards")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(declineTitle, action: onCancel)
            .accessibilityIdentifier("agreement.cancel")
        }
      }
    }
    .modifier(CommunityStandardsSheetFrame())
    .interactiveDismissDisabled()
  }
}

/// macOS sheets size to their content's ideal size; this one's wrapping text would
/// ask for a single long line, so give the sheet a readable size there. iOS is unchanged.
private struct CommunityStandardsSheetFrame: ViewModifier {
  func body(content: Content) -> some View {
    #if os(macOS)
    content.frame(minWidth: 440, idealWidth: 520, minHeight: 420, idealHeight: 560)
    #else
    content
    #endif
  }
}

/// Asks a signed-in account that hasn't accepted the current agreement to accept it,
/// including accounts restored from an earlier session or added before it existed.
/// Declining signs the account out.
struct CommunityStandardsGate: ViewModifier {
  let accountDID: String
  let onDecline: @MainActor () async -> Void

  @State private var isPresented = false

  func body(content: Content) -> some View {
    content
      .task(id: accountDID) {
        if CommunityStandards.consumeAcceptanceBeforeSignIn() {
          CommunityStandards.recordAcceptance(for: accountDID)
        }
        isPresented = !CommunityStandards.hasAcceptedCurrentVersion(for: accountDID)
      }
      .sheet(isPresented: $isPresented) {
        CommunityStandardsAgreementView(
          declineTitle: "Sign Out",
          onAgree: {
            CommunityStandards.recordAcceptance(for: accountDID)
            isPresented = false
          },
          onCancel: {
            isPresented = false
            Task { await onDecline() }
          }
        )
      }
  }
}
