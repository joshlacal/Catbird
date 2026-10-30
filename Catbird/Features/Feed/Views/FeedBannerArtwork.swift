import SwiftUI

/// Keeps sharp banner artwork below top controls while extending its colors
/// behind them. The enclosing header owns stretching and concentric clipping.
struct FeedBannerArtwork<Artwork: View>: View {
  let topInset: CGFloat
  @ViewBuilder var artwork: () -> Artwork

  var body: some View {
    GeometryReader { geometry in
      let inset = max(0, topInset)
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
          .mask {
            VStack(spacing: 0) {
              LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: inset > 0 ? min(56, artworkHeight) : 0)
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
