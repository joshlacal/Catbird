import SwiftUI

/// Extends banner colors behind the top controls with a compact blurred band.
/// The enclosing header owns safe-area sizing, stretching and clipping.
struct FeedBannerArtwork<Artwork: View>: View {
  let topInset: CGFloat
  @ViewBuilder var artwork: () -> Artwork

  var body: some View {
    GeometryReader { geometry in
      // The safe area sizes the whole header, not the amount of artwork to blur.
      // Keep half the previous extension and blend so sharp art starts sooner.
      let inset = min(max(0, topInset) * 0.5, max(0, geometry.size.height) * 0.5)
      let artworkHeight = max(1, geometry.size.height - inset)

      ZStack(alignment: .top) {
        // Reflect the same crop above its top edge. Both copies have the sharp
        // artwork's dimensions, so the blur meets matching colors at the seam.
        VStack(spacing: 0) {
          artwork()
            .frame(width: geometry.size.width, height: artworkHeight)
            .scaleEffect(x: 1, y: -1)
          artwork()
            .frame(width: geometry.size.width, height: artworkHeight)
        }
        .compositingGroup()
        .blur(radius: 24, opaque: true)
        .offset(y: inset - artworkHeight)
        .accessibilityHidden(true)

        artwork()
          .frame(width: geometry.size.width, height: artworkHeight)
          .mask(alignment: .top) {
            VStack(spacing: 0) {
              LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: inset > 0 ? min(14, artworkHeight) : 0)
              Color.black
            }
          }
          .offset(y: inset)
      }
      .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
      .clipped()
    }
  }
}
