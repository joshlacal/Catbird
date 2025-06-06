import SwiftUI
import NukeUI
import Petrel

struct ExternalEmbedView: View {
    let external: AppBskyEmbedExternal.ViewExternal
    let shouldBlur: Bool
    let postID: String
    @State private var isBlurred: Bool
    @State private var userOverrideBlock = false
    @Environment(AppState.self) private var appState
    @State private var videoModel: VideoModel?
    
    init(external: AppBskyEmbedExternal.ViewExternal, shouldBlur: Bool, postID: String) {
        self.external = external
        self.shouldBlur = shouldBlur
        self._isBlurred = State(initialValue: shouldBlur)
        self.postID = postID
    }
    
    var body: some View {
        if shouldShowExternalEmbed(for: external.uri) || userOverrideBlock {
            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(maxWidth: .infinity)
            }
            .onTapGesture {
                if let url = URL(string: external.uri.uriString()) {
                    _ = appState.urlHandler.handle(url)
                }
            }
            .onAppear {
                setupVideoIfNeeded()
            }
            // Fixed sizing to prevent layout jumps
            .fixedSize(horizontal: false, vertical: true)
        } else {
            blockedExternalMediaView
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let videoModel = videoModel {
                // Video player - no blur handling when shouldBlur is false (ContentLabelManager handles it)
                if shouldBlur {
                    ZStack(alignment: .topTrailing) {
                        ModernVideoPlayerView18(
                            model: videoModel,
                            postID: postID
                        )
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
                        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .blur(radius: isBlurred ? 60 : 0)
                        
                        blurToggleButton
                        
                        if isBlurred {
                            sensitiveContentOverlay
                        }
                    }
                } else {
                    // Simple video display when ContentLabelManager handles filtering
                    ModernVideoPlayerView18(
                        model: videoModel,
                        postID: postID
                    )
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: UIScreen.main.bounds.height * 0.6)
                    .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            } else {
                // Link card - no blur handling when shouldBlur is false
                if shouldBlur {
                    VStack(alignment: .leading, spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            thumbnailImageContent
                                .blur(radius: isBlurred ? 60 : 0)
                            
                            blurToggleButton
                            
                            if isBlurred {
                                sensitiveContentOverlay
                            }
                        }
                        
                        linkDetails
                    }
                    .padding(6)
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                } else {
                    // Simple link display when ContentLabelManager handles filtering
                    VStack(alignment: .leading, spacing: 3) {
                        thumbnailImageContent
                        linkDetails
                    }
                    .padding(6)
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                }
            }
        }
    }
    
    @ViewBuilder
    private var thumbnailImageContent: some View {
        if let thumbURL = external.thumb?.url {
            ZStack(alignment: .bottomLeading) {
                // Same as existing thumbnailImage implementation
                // but without the blur modifier (moved to parent)
                RoundedRectangle(cornerRadius: 7, style: .circular)
                    .fill(Color.clear)
                    .aspectRatio(1.91 / 1, contentMode: .fit)
                    .overlay(
                        LazyImage(url: thumbURL) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity)
                                    .clipped()
                            } else if state.isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                Color.gray
                            }
                        }
                        .animation(.default, value: isBlurred)
                        .cornerRadius(7)
                    )
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                
                Text(external.uri.authority)
                    .appFont(AppTextRole.caption)
                    .lineLimit(1)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                    .padding(8)
            }
            .frame(maxWidth: .infinity)
        } else {
            // Keep the existing non-image implementation
            HStack(alignment: .center) {
                Image(systemName: "arrow.up.right.square")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.gray)
                    .frame(width: 20, height: 20)
                Text(external.uri.authority)
                    .appFont(AppTextRole.headline)
                    .textScale(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }
    
    // New Blur Toggle Button
    @ViewBuilder
    private var blurToggleButton: some View {
        Button(action: {
            withAnimation {
                isBlurred.toggle()
            }
        }) {
            Image(systemName: isBlurred ? "eye.slash.fill" : "eye.fill")
                .foregroundColor(.white)
                .padding(8)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
        }
        .padding(8)
        .zIndex(2) // Ensure button is above the blur
    }
    
    // Sensitive Content Overlay
    @ViewBuilder
    private var sensitiveContentOverlay: some View {
        VStack {
            Text("Sensitive Content")
                .foregroundColor(.white)
                .padding(6)
                .background(Color.black.opacity(0.7))
                .cornerRadius(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(1)
    }

    private func setupVideoIfNeeded() {
        guard let url = URL(string: external.uri.uriString()),
              url.host == "media.tenor.com" else {
            return
        }
        
        // Extract aspect ratio from URL parameters
        let aspectRatio: CGFloat = {
            if let widthStr = url.queryParameters?["ww"],
               let heightStr = url.queryParameters?["hh"],
               let width = Double(widthStr),
               let height = Double(heightStr),
               width > 0, height > 0 {
                return CGFloat(width / height)
            }
            return 1.0
        }()
        
        // Transform Tenor URL to direct MP4 URL
        let pathComponents = url.path.split(separator: "/")
        if let idComponent = pathComponents.first {
            let videoId = String(idComponent).replacingOccurrences(of: "AAAAC", with: "AAAPo")
            if let mp4URL = URL(string: "https://media.tenor.com/\(videoId)/video.mp4") {
                // Create VideoModel for Tenor GIF
                videoModel = VideoModel(
                    id: url.absoluteString,
                    url: mp4URL,
                    type: .tenorGif(external.uri),
                    aspectRatio: aspectRatio
                )
            }
        }
    }
    
    @ViewBuilder
    private var blurOverlay: some View {
        if isBlurred {
            VStack {
                Text("Sensitive Content")
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                Text("Tap to reveal")
                    .foregroundColor(.white)
                    .appFont(AppTextRole.caption)
            }
        }
    }
    
    @ViewBuilder
    private var linkCardView: some View {
        VStack(alignment: .leading, spacing: 3) {
            thumbnailImage
            linkDetails
        }
    }
    
    @ViewBuilder
    private var thumbnailImage: some View {
        if let thumbURL = URL(string: external.thumb?.uriString() ?? "") {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 7, style: .circular)
                    .fill(Color.clear)
                    .aspectRatio(1.91 / 1, contentMode: .fit)
                    .overlay(
                        LazyImage(url: thumbURL) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(maxWidth: .infinity)
                                    .clipped()
                                    .blur(radius: isBlurred ? 60 : 0)
                            } else if state.isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                Color.gray
                            }
                        }
                            .animation(.default, value: isBlurred)
                            .cornerRadius(7)
                    )
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                
                Text(external.uri.authority)
                    .appFont(AppTextRole.caption)
                    .lineLimit(1)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(10)
                    .padding(8)
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .center) {
                Image(systemName: "arrow.up.right.square")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.gray)
                    .frame(width: 20, height: 20)
                Text(external.uri.authority)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }
    
    @ViewBuilder
    private var linkDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !external.title.isEmpty {
                Text(external.title)
                    .appFont(AppTextRole.headline)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }
            
            if !external.description.isEmpty {
                Text(external.description)
                    .appFont(AppTextRole.subheadline)
                    .lineLimit(3)
                    .truncationMode(.tail)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func handleTap() {
        if isBlurred {
            // Simply remove blur when tapped while blurred
            withAnimation {
                isBlurred = false
            }
        } else if let url = URL(string: external.uri.uriString()) {
            // Handle URL tap when content is visible
            _ = appState.urlHandler.handle(url)
        }
    }
    
    // MARK: - External Media Filtering
    
    /// Check if external media should be shown based on user settings
    private func shouldShowExternalEmbed(for uri: URI) -> Bool {
        guard let host = URL(string: uri.uriString())?.host?.lowercased() else { return true }
        
        switch host {
        case let h where h.contains("youtube.com") || h.contains("youtu.be"):
            // Check for YouTube Shorts specifically
            if uri.uriString().contains("/shorts/") {
                return appState.appSettings.allowYouTubeShorts
            }
            return appState.appSettings.allowYouTube
        case let h where h.contains("vimeo.com"):
            return appState.appSettings.allowVimeo
        case let h where h.contains("twitch.tv"):
            return appState.appSettings.allowTwitch
        case let h where h.contains("giphy.com"):
            return appState.appSettings.allowGiphy
        case let h where h.contains("tenor.com"):
            return appState.appSettings.allowTenor
        case let h where h.contains("spotify.com"):
            return appState.appSettings.allowSpotify
        case let h where h.contains("music.apple.com"):
            return appState.appSettings.allowAppleMusic
        case let h where h.contains("soundcloud.com"):
            return appState.appSettings.allowSoundCloud
        case let h where h.contains("flickr.com"):
            return appState.appSettings.allowFlickr
        default:
            return true // Allow unknown external sites by default
        }
    }
    
    /// View shown when external media is blocked
    @ViewBuilder
    private var blockedExternalMediaView: some View {
        VStack(spacing: 8) {
            blockedMediaHeader
            blockedMediaButtons
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private var blockedMediaHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "link.badge.plus")
                .foregroundStyle(.secondary)
                .imageScale(.medium)
            
            blockedMediaText
            
            Spacer()
        }
    }
    
    @ViewBuilder
    private var blockedMediaText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("External media blocked")
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(.secondary)
            
            blockedMediaHostText
        }
    }
    
    @ViewBuilder
    private var blockedMediaHostText: some View {
        if let host = external.uri.url?.host {
            Text("Content from \(host)")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.tertiary)
        }
    }
    
    @ViewBuilder
    private var blockedMediaButtons: some View {
        HStack(spacing: 12) {
            Button("Show Anyway") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    userOverrideBlock = true
                }
            }
            .appFont(AppTextRole.caption)
            .foregroundStyle(.blue)
            
            Spacer()
            
            // Note: Settings access is handled through the main profile tab
            // Users can access Content & Media settings from there
        }
    }
}

// Helper URL extension
extension URL {
    var queryParameters: [String: String]? {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else { return nil }
        return queryItems.reduce(into: [String: String]()) { result, item in
            result[item.name] = item.value
        }
    }
}
