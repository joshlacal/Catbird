import SwiftUI

/// Lane-local empty/error state without its own background, for screens that
/// already paint a themed grouped background. Mirrors ContentUnavailableStateView.
struct ListsStateView: View {
  let title: String
  let description: String?
  let systemImage: String
  var iconTint: Color = .secondary
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: Space.lg) {
      Image(systemName: systemImage)
        .appFont(size: 64)
        .foregroundStyle(iconTint)
        .accessibilityHidden(true)

      VStack(spacing: Space.sm) {
        Text(title)
          .appFont(AppTextRole.title2)
          .fontWeight(.semibold)
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)

        if let description, !description.isEmpty {
          Text(description)
            .appFont(AppTextRole.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }

      if let actionTitle, let action {
        Button(actionTitle) { action() }
          .buttonStyle(.catbird(.primary, size: .lg))
      }
    }
    .padding(Space.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
  }
}
