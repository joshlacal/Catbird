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
}

/// Asks for explicit agreement to the Terms of Service and Community Guidelines,
/// including zero tolerance for objectionable content and abusive users, before
/// someone signs in or creates an account.
struct CommunityStandardsAgreementView: View {
  let onAgree: () -> Void
  let onCancel: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("Catbird has zero tolerance for objectionable content and abusive users.")
            .appFont(AppTextRole.headline)

          Text("Posts, replies, messages and accounts that harass, threaten, exploit or abuse others are not allowed. Reported content is reviewed by Bluesky's moderation service and can be labeled or removed, and accounts that break these rules can be suspended.")
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
          Button("Cancel", action: onCancel)
            .accessibilityIdentifier("agreement.cancel")
        }
      }
    }
    .interactiveDismissDisabled()
  }
}
