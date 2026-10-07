import Foundation
import SwiftUI

/// Policy links shown on the sign-in screen.
enum CommunityStandards {
  static let communityGuidelinesURL = URL(string: "https://bsky.social/about/support/community-guidelines")!

  static var termsOfServiceURL: URL {
    LegalConfig.termsOfServiceURL ?? URL(string: "https://catbird.blue/terms")!
  }
}
