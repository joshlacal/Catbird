import SwiftUI

private struct ChatTranscriptBottomInsetKey: EnvironmentKey {
  static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
  var chatTranscriptBottomInset: CGFloat {
    get { self[ChatTranscriptBottomInsetKey.self] }
    set { self[ChatTranscriptBottomInsetKey.self] = newValue }
  }
}

/// SwiftUI owns navigation and keyboard avoidance. Only the measured footer is
/// reserved by the collection's content inset, so messages scroll behind glass.
private struct ChatTranscriptViewport<Footer: View>: ViewModifier {
  let footer: Footer
  @State private var footerHeight: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .environment(\.chatTranscriptBottomInset, footerHeight)
      .overlay(alignment: .bottom) {
        VStack(spacing: 0) { footer }
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            footerHeight = max(0, height)
          }
      }
  }
}

extension View {
  func chatTranscriptViewport<Footer: View>(@ViewBuilder footer: () -> Footer) -> some View {
    modifier(ChatTranscriptViewport(footer: footer()))
  }
}
