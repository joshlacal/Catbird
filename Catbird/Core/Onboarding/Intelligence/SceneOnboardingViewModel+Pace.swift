import Foundation
import PetrelCatbird

// MARK: - Pace Wording

extension SceneOnboardingViewModel {
  /// The line under a pace option. A live server follows the same accounts at every pace and only
  /// changes what it delivers from them, so its options never state an account count.
  public func paceSubtitle(for option: BlueCatbirdOnboardingDefs.BundleControlsPace) -> String {
    guard isLiveEngine else {
      switch option {
      case .value_calm:
        return String(localized: "~18 voices", comment: "Approximate voice count subtitle for Calm pace option.")
      case .value_balanced:
        return String(localized: "~25 voices", comment: "Approximate voice count subtitle for Balanced pace option.")
      case .value_lively:
        return String(localized: "~34 voices", comment: "Approximate voice count subtitle for Lively pace option.")
      }
    }
    switch option {
    case .value_calm:
      return originalsOnlyForHeavyReposters
        ? String(localized: "Fewer reposts", comment: "Pace option subtitle when heavy reposters are set to originals-only.")
        : String(localized: "Every post", comment: "Pace option subtitle when all posts and reposts are shown.")
    case .value_balanced, .value_lively:
      return String(localized: "Every post", comment: "Pace option subtitle when all posts and reposts are shown.")
    }
  }

  /// A note under the pace options for a live server, which keeps the lineup the same at every pace.
  public var paceFootnote: String? {
    guard isLiveEngine else { return nil }
    return String(
      localized: "Pace changes how much you see from heavy reposters, never who you follow.",
      comment: "Explanatory footnote under pace options in scene onboarding."
    )
  }
}
