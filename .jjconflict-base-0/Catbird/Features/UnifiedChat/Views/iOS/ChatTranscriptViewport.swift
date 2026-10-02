import SwiftUI

/// SwiftUI owns navigation, keyboard, and the actual footer height. The UIKit
/// transcript fills only the proposed viewport and adds no duplicate occlusion.
extension View {
  func chatTranscriptViewport<Footer: View>(@ViewBuilder footer: () -> Footer) -> some View {
    safeAreaInset(edge: .bottom, spacing: 0, content: footer)
  }
}
