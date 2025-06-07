import Foundation
import SwiftUI

/// Navigation destinations specific to the Profile feature
enum ProfileNavigationDestination: Hashable {
  case section(ProfileTab)
  case followers(String)
  case following(String)
}
