import Petrel
import SwiftUI

/// A name and author badges inside a record card. The caller supplies that record's
/// author metadata; no handle lookup or parent-post identity is inferred.
struct EmbeddedAuthorNameView: View {
  let name: String
  let verification: AppBskyActorDefs.VerificationState?
  let isAutomated: Bool
  @Environment(AppState.self) private var appState: AppState?

  init(name: String, verification: AppBskyActorDefs.VerificationState? = nil, isAutomated: Bool = false) {
    self.name = name
    self.verification = verification
    self.isAutomated = isAutomated
  }

  private var badgeKind: VerificationBadgeKind? {
    VerificationBadge.metadataKind(
      for: verification,
      hideBadges: appState?.preferencesManager.hideVerificationBadges ?? false
    )
  }

  var body: some View {
    let kind = badgeKind
    let accessibilityName = (kind.map { "\(name), \($0.accessibilityLabel)" } ?? name)
      + (isAutomated ? ", \(AutomationBadge.accessibilityLabel)" : "")
    HStack(spacing: 4) {
      Text(name)
        .lineLimit(1)
        .truncationMode(.tail)
      if let kind {
        VerificationBadgeView(kind: kind)
          .font(.caption)
          .fixedSize()
          .layoutPriority(1)
      }
      if isAutomated {
        AutomationBadgeView()
          .font(.caption)
          .fixedSize()
          .layoutPriority(1)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityName)
  }
}
