import SwiftUI
import NukeUI

/// A simple view that displays GIFs using LazyImage with aspect ratio support for masonry layout
struct SimpleGifView: View {
    let gif: TenorGif
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            ZStack {
                LazyImage(url: bestGifURL) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(aspectRatio, contentMode: .fit)
                    } else if state.isLoading {
                        loadingView
                    } else {
                        placeholderView
                    }
                }
                .aspectRatio(aspectRatio, contentMode: .fit)
                .cornerRadius(8)
                
                // GIF indicator overlay
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("GIF")
                            .appFont(AppTextRole.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(4)
                            .padding(6)
                    }
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
    
    @ViewBuilder
    private var loadingView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(platformColor: .platformSystemGray6))
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(
                ProgressView()
            )
    }
    
    @ViewBuilder
    private var placeholderView: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(platformColor: .platformSystemGray5))
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(
                Image(systemName: "photo")
                    .foregroundColor(.secondary)
            )
    }
    
    /// Get the best GIF URL for animation (prioritize actual GIF formats)
    private var bestGifURL: URL? {
        // Priority: gif > mediumgif > tinygif > nanogif for animation
        if let gif = gif.media_formats.gif {
            return URL(string: gif.url)
        } else if let mediumgif = gif.media_formats.mediumgif {
            return URL(string: mediumgif.url)
        } else if let tinygif = gif.media_formats.tinygif {
            return URL(string: tinygif.url)
        } else if let nanogif = gif.media_formats.nanogif {
            return URL(string: nanogif.url)
        }
        return nil
    }
    
    /// Calculate aspect ratio from Tenor's media format dimensions
    private var aspectRatio: CGFloat {
        func safeRatio(_ dims: [Int]) -> CGFloat? {
            guard dims.count >= 2 else { return nil }
            let width = CGFloat(dims[0])
            let height = CGFloat(dims[1])
            guard width > 0, height > 0 else { return nil }
            let ratio = width / height
            return (ratio.isFinite && ratio > 0) ? ratio : nil
        }

        // Try to get dimensions from the best available format
        if let gif = gif.media_formats.gif, let ratio = safeRatio(gif.dims) {
            return ratio
        } else if let mediumgif = gif.media_formats.mediumgif, let ratio = safeRatio(mediumgif.dims) {
            return ratio
        } else if let tinygif = gif.media_formats.tinygif, let ratio = safeRatio(tinygif.dims) {
            return ratio
        }

        // Default to square aspect ratio if no/invalid dimensions available
        return 1.0
    }
}