import Foundation
import SwiftUI

/// Policy links and notice shown with the sign-in buttons.
enum CommunityStandards {
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
}
