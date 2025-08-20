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
        // Try to get dimensions from the best available format
        if let gif = gif.media_formats.gif, gif.dims.count >= 2 {
            let width = CGFloat(gif.dims[0])
            let height = CGFloat(gif.dims[1])
            return width / height
        } else if let mediumgif = gif.media_formats.mediumgif, mediumgif.dims.count >= 2 {
            let width = CGFloat(mediumgif.dims[0])
            let height = CGFloat(mediumgif.dims[1])
            return width / height
        } else if let tinygif = gif.media_formats.tinygif, tinygif.dims.count >= 2 {
            let width = CGFloat(tinygif.dims[0])
            let height = CGFloat(tinygif.dims[1])
            return width / height
        }
        // Default to square aspect ratio if no dimensions available
        return 1.0
    }
}