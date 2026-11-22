import Foundation
import PetrelCatbird

// MARK: - Pace Wording

extension SceneOnboardingViewModel {
  /// The line under a pace option. A live server follows the same accounts at every pace and only
  /// changes what it delivers from them, so its options never state an account count.
  public func paceSubtitle(for option: BlueCatbirdOnboardingDefs.BundleControlsPace) -> String {
    guard isLiveEngine else {
      switch option {
      case .value_calm: return "~18 voices"
      case .value_balanced: return "~25 voices"
      case .value_lively: return "~34 voices"
      }
    }
    switch option {
    case .value_calm:
      return originalsOnlyForHeavyReposters ? "Fewer reposts" : "Every post"
    case .value_balanced, .value_lively:
      return "Every post"
    }
  }

  /// A note under the pace options for a live server, which keeps the lineup the same at every pace.
  public var paceFootnote: String? {
    guard isLiveEngine else { return nil }
    return "Pace changes how much you see from heavy reposters, never who you follow."
  }
}
