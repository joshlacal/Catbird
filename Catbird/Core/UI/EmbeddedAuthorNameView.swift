import Petrel
import SwiftUI

/// A verified name inside a record card. The caller supplies that record's
/// author metadata; no handle lookup or parent-post identity is inferred.
struct EmbeddedAuthorNameView: View {
  let name: String
  let verification: AppBskyActorDefs.VerificationState?
  @Environment(AppState.self) private var appState: AppState?

  private var badgeKind: VerificationBadgeKind? {
    VerificationBadge.metadataKind(
      for: verification,
      hideBadges: appState?.preferencesManager.hideVerificationBadges ?? false
    )
  }

  var body: some View {
    let kind = badgeKind
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
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(kind.map { "\(name), \($0.accessibilityLabel)" } ?? name)
  }
}
