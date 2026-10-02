import SwiftUI

/// Anchors edit controls to the artwork rather than the tile's text or width.
/// Semantic trailing alignment mirrors the corner in right-to-left layouts.
struct FeedRemovalBadgeOverlay: ViewModifier {
  let isEditing: Bool
  let iconSize: CGFloat
  let iconTopInset: CGFloat
  let action: () -> Void

  func body(content: Content) -> some View {
    content.overlay(alignment: .top) {
      if isEditing {
        Color.clear
          .frame(width: iconSize, height: iconSize)
          .allowsHitTesting(false)
          .overlay(alignment: .topTrailing) {
            Button(action: action) {
              Image(systemName: "minus.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.red)
                .background(.white, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove feed")
            // Center the visible circle and its touch target on the corner.
            .alignmentGuide(.top) { $0[VerticalAlignment.center] }
            .alignmentGuide(.trailing) { $0[HorizontalAlignment.center] }
          }
          .padding(.top, iconTopInset)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: isEditing)
  }
}
