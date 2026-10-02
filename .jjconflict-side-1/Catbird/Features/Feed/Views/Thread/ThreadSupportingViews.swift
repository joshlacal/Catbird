#if os(iOS)
import Petrel
import SwiftUI

// MARK: - Supporting SwiftUI Views
/// Centers its content and constrains it to a maximum width while allowing the
/// surrounding container (e.g., collection view cell) to be full-width.
struct WidthLimitedContainer<Content: View>: View {
  @Environment(\.horizontalSizeClass) private var hSizeClass
  let maxWidth: CGFloat
  @ViewBuilder var content: Content

  private var effectiveMaxWidth: CGFloat {
    hSizeClass == .compact ? .infinity : maxWidth
  }

  init(maxWidth: CGFloat = 600, @ViewBuilder content: () -> Content) {
    self.maxWidth = maxWidth
    self.content = content()
  }

  var body: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      content
        .frame(maxWidth: effectiveMaxWidth, alignment: .center)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity)
  }
}
#endif
