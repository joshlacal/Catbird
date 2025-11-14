import SwiftUI
import NukeUI
import Petrel
import WebKit
import os.log

struct ExternalEmbedView: View {
    let external: AppBskyEmbedExternal.ViewExternal
    let shouldBlur: Bool
    let postID: String
    @State private var isBlurred: Bool
    @State private var userOverrideBlock = false
    @State private var userTappedToShowEmbed = false
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var videoModel: VideoModel?
    @State private var gifError: String?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "ExternalEmbedView")
    
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
            .environment(
                \.openURL,
                 OpenURLAction { url in
                     let result = appState.urlHandler.handle(url)
                     return result
                 })
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
        if let videoModel = videoModel {
            videoPlayerContent(videoModel: videoModel)
        } else if let gifError = gifError {
            gifErrorContent(error: gifError)
        } else if let url = URL(string: external.uri.uriString()),
                  appState.appSettings.useWebViewEmbeds,
                  userTappedToShowEmbed,
                  let embedType = ExternalMediaType.detect(from: url),
                  shouldShowWebViewEmbed(for: embedType) {
            webViewEmbedContent(url: url, embedType: embedType)
        } else {
            linkCardContent()
        }
    }
    
    @ViewBuilder
    private func videoPlayerContent(videoModel: VideoModel) -> some View {
        // ContentLabelManager handles all blur logic now
        ModernVideoPlayerView(
            model: videoModel,
            postID: postID
        )
        .frame(maxWidth: .infinity)
        .frame(maxHeight: PlatformScreenInfo.height * 0.6)
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    
    @ViewBuilder
    private func webViewEmbedContent(url: URL, embedType: ExternalMediaType) -> some View {
        VStack(spacing: 6) {
            EmbeddedMediaWebView(url: url, embedType: embedType, shouldBlur: shouldBlur)
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            // Hide embed button
            HStack {
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        userTappedToShowEmbed = false
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "minus.rectangle.fill")
                            .imageScale(.small)
                        Text("Hide Embed")
                            .appFont(AppTextRole.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    @ViewBuilder
    private func linkCardContent() -> some View {
        let canShowEmbed = appState.appSettings.useWebViewEmbeds &&
                          URL(string: external.uri.uriString()) != nil &&
                          ExternalMediaType.detect(from: URL(string: external.uri.uriString())!) != nil &&
                          shouldShowWebViewEmbed(for: ExternalMediaType.detect(from: URL(string: external.uri.uriString())!)!)

        // ContentLabelManager handles all blur logic now - no need for shouldBlur checks
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
        .onTapGesture {
            if canShowEmbed {
                // Show webview embed
                withAnimation(.easeInOut(duration: 0.3)) {
                    userTappedToShowEmbed = true
                }
            } else {
                // Open URL in browser
                if let url = URL(string: external.uri.uriString()) {
                    _ = appState.urlHandler.handle(url)
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
                            } else {
                                // Don't show spinner for chat embeds - just use empty view
                                EmptyView()
                            }
                        }
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
        guard let url = URL(string: external.uri.uriString()) else {
            logger.debug("❌ Failed to create URL from external URI: \(external.uri.uriString())")
            return
        }
        
        logger.debug("🔍 Checking URL for GIF conversion: \(url.absoluteString)")
        logger.debug("🔍 URL host: \(url.host ?? "nil")")
        logger.debug("🔍 App settings - allowGiphy: \(appState.appSettings.allowGiphy), allowTenor: \(appState.appSettings.allowTenor), autoplayVideos: \(appState.appSettings.autoplayVideos)")
        
        // Handle Tenor GIFs
        if url.host == "media.tenor.com" {
            logger.debug("🎬 Detected Tenor GIF, attempting conversion...")
            setupTenorVideo(from: url)
        }
        // Handle Giphy GIFs
        else if url.host?.contains("giphy.com") == true || url.host?.contains("media.giphy.com") == true {
            logger.debug("🎬 Detected Giphy GIF, attempting conversion...")
            setupGiphyVideo(from: url)
        } else {
            logger.debug("ℹ️ URL is not a recognized GIF host, treating as regular external link")
        }
    }
    
    private func setupTenorVideo(from url: URL) {
        logger.debug("🎬 Setting up Tenor video from URL: \(url.absoluteString)")
        
        // Extract aspect ratio from URL parameters
        let aspectRatio: CGFloat = {
            if let widthStr = url.queryParameters?["ww"],
               let heightStr = url.queryParameters?["hh"],
               let width = Double(widthStr),
               let height = Double(heightStr),
               width > 0, height > 0 {
                logger.debug("🎬 Extracted aspect ratio from URL params: \(width)x\(height) = \(width/height)")
                return CGFloat(width / height)
            }
            logger.debug("🎬 Using default aspect ratio 1.0 (no valid dimensions in URL)")
            return 1.0
        }()
        
        // Transform Tenor URL to direct MP4 URL
        let pathComponents = url.path.split(separator: "/")
        logger.debug("🎬 Tenor URL path components: \(pathComponents)")
        
        if let idComponent = pathComponents.first {
            let videoId = String(idComponent).replacingOccurrences(of: "AAAAC", with: "AAAPo")
            logger.debug("🎬 Transformed Tenor ID: '\(idComponent)' -> '\(videoId)'")
            
            if let mp4URL = URL(string: "https://media.tenor.com/\(videoId)/video.mp4") {
                logger.debug("✅ Created Tenor MP4 URL: \(mp4URL.absoluteString)")
                
                // Validate the MP4 URL before creating VideoModel
                Task {
                    await validateAndCreateTenorModel(mp4URL: mp4URL, aspectRatio: aspectRatio, originalURL: url)
                }
            } else {
                logger.debug("❌ Failed to create MP4 URL for Tenor video ID: \(videoId)")
                gifError = "Failed to create MP4 URL"
            }
        } else {
            logger.debug("❌ No path components found in Tenor URL: \(url.path)")
            gifError = "Failed to parse Tenor GIF URL"
        }
    }
    
    private func validateAndCreateTenorModel(mp4URL: URL, aspectRatio: CGFloat, originalURL: URL) async {
        do {
            // Quick HEAD request to validate MP4 URL
            var request = URLRequest(url: mp4URL)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5.0
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    logger.debug("✅ Tenor MP4 URL validated: \(mp4URL.absoluteString)")
                    
                    await MainActor.run {
                        // Create VideoModel for Tenor GIF with unique ID including postID
                        let model = VideoModel(
                            id: "\(postID)-tenor-\(originalURL.absoluteString)",
                            url: mp4URL,
                            type: .tenorGif(external.uri),
                            aspectRatio: aspectRatio,
                            thumbnailURL: external.thumb?.url
                        )
                        videoModel = model
                        logger.debug("✅ Created VideoModel for Tenor GIF: \(model.id)")
                    }
                } else {
                    logger.debug("❌ Tenor MP4 URL returned status \(httpResponse.statusCode): \(mp4URL.absoluteString)")
                    await MainActor.run {
                        gifError = "MP4 conversion failed (status \(httpResponse.statusCode))"
                    }
                }
            }
        } catch {
            logger.debug("❌ Failed to validate Tenor MP4 URL: \(error)")
            await MainActor.run {
                gifError = "Unable to load MP4 version"
            }
        }
    }
    
    private func setupGiphyVideo(from url: URL) {
        logger.debug("🎬 Setting up Giphy video from URL: \(url.absoluteString)")
        
        // Extract GIF ID from various Giphy URL formats
        let giphyId: String? = {
            let urlString = url.absoluteString
            logger.debug("🎬 Giphy URL string: \(urlString)")
            
            // Handle media.giphy.com/media/{id}/giphy.gif format
            if url.host?.contains("media.giphy.com") == true {
                let pathComponents = url.path.split(separator: "/")
                logger.debug("🎬 Giphy path components (media.giphy.com): \(pathComponents)")
                if let mediaIndex = pathComponents.firstIndex(of: "media"),
                   mediaIndex + 1 < pathComponents.count {
                    let id = String(pathComponents[mediaIndex + 1])
                    logger.debug("🎬 Extracted Giphy ID from media.giphy.com: \(id)")
                    return id
                }
            }
            // Handle giphy.com/gifs/{name}-{id} format
            else if url.path.contains("/gifs/") {
                let pathComponents = url.path.split(separator: "/")
                logger.debug("🎬 Giphy path components (giphy.com/gifs): \(pathComponents)")
                if let gifsIndex = pathComponents.firstIndex(of: "gifs"),
                   gifsIndex + 1 < pathComponents.count {
                    let gifPath = String(pathComponents[gifsIndex + 1])
                    // Extract ID from the end after the last dash
                    let id = gifPath.split(separator: "-").last.map(String.init)
                    logger.debug("🎬 Extracted Giphy ID from gifs path: \(id ?? "nil")")
                    return id
                }
            }
            // Handle giphy.com/embed/{id} format
            else if url.path.contains("/embed/") {
                let pathComponents = url.path.split(separator: "/")
                logger.debug("🎬 Giphy path components (embed): \(pathComponents)")
                let id = pathComponents.last.map(String.init)
                logger.debug("🎬 Extracted Giphy ID from embed: \(id ?? "nil")")
                return id
            }
            
            logger.debug("❌ Could not extract Giphy ID from URL format")
            return nil
        }()
        
        guard let gifId = giphyId else {
            logger.debug("❌ No Giphy ID found, cannot convert to MP4")
            gifError = "Failed to parse Giphy GIF URL"
            return
        }
        
        // Create MP4 URL for Giphy
        if let mp4URL = URL(string: "https://media.giphy.com/media/\(gifId)/giphy.mp4") {
            logger.debug("✅ Created Giphy MP4 URL: \(mp4URL.absoluteString)")
            
            // Validate the MP4 URL before creating VideoModel
            Task {
                await validateAndCreateGiphyModel(mp4URL: mp4URL, gifId: gifId)
            }
        } else {
            logger.debug("❌ Failed to create MP4 URL for Giphy ID: \(gifId)")
            gifError = "Failed to create MP4 URL"
        }
    }
    
    private func validateAndCreateGiphyModel(mp4URL: URL, gifId: String) async {
        do {
            // Quick HEAD request to validate MP4 URL
            var request = URLRequest(url: mp4URL)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5.0
            
            let (_, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    logger.debug("✅ Giphy MP4 URL validated: \(mp4URL.absoluteString)")
                    
                    await MainActor.run {
                        // Default aspect ratio for Giphy GIFs (will be updated when video loads)
                        let aspectRatio: CGFloat = 1.0
                        
                        // Create VideoModel for Giphy GIF with unique ID including postID
                        let model = VideoModel(
                            id: "\(postID)-giphy-\(gifId)",
                            url: mp4URL,
                            type: .giphyGif(external.uri),
                            aspectRatio: aspectRatio,
                            thumbnailURL: external.thumb?.url
                        )
                        videoModel = model
                        logger.debug("✅ Created VideoModel for Giphy GIF: \(model.id)")
                    }
                } else {
                    logger.debug("❌ Giphy MP4 URL returned status \(httpResponse.statusCode): \(mp4URL.absoluteString)")
                    await MainActor.run {
                        gifError = "MP4 conversion failed (status \(httpResponse.statusCode))"
                    }
                }
            }
        } catch {
            logger.debug("❌ Failed to validate Giphy MP4 URL: \(error)")
            await MainActor.run {
                gifError = "Unable to load MP4 version"
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
                            } else {
                                // Don't show spinner for chat embeds - just use empty view
                                EmptyView()
                            }
                        }
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

            // Show subtle indicator if embed is available
            if appState.appSettings.useWebViewEmbeds,
               let url = URL(string: external.uri.uriString()),
               let embedType = ExternalMediaType.detect(from: url),
               shouldShowWebViewEmbed(for: embedType) {
                HStack(spacing: 4) {
                    Image(systemName: "play.rectangle")
                        .imageScale(.small)
                    Text(embedTypeLabel(embedType))
                        .appFont(AppTextRole.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private func embedTypeLabel(_ embedType: ExternalMediaType) -> String {
        switch embedType {
        case .youtube, .youtubeShorts:
            return "YouTube"
        case .vimeo:
            return "Vimeo"
        case .twitch:
            return "Twitch"
        case .spotify:
            return "Spotify"
        case .appleMusic:
            return "Apple Music"
        case .soundcloud:
            return "SoundCloud"
        case .giphy:
            return "GIPHY"
        case .tenor:
            return "Tenor"
        case .flickr:
            return "Flickr"
        }
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
    
    /// Check if WebView embeds should be shown for specific media types
    private func shouldShowWebViewEmbed(for embedType: ExternalMediaType) -> Bool {
        switch embedType {
        case .youtube:
            return appState.appSettings.allowYouTube
        case .youtubeShorts:
            return appState.appSettings.allowYouTubeShorts
        case .vimeo:
            return appState.appSettings.allowVimeo
        case .twitch:
            return appState.appSettings.allowTwitch
        case .spotify:
            return appState.appSettings.allowSpotify
        case .appleMusic:
            return appState.appSettings.allowAppleMusic
        case .soundcloud:
            return appState.appSettings.allowSoundCloud
        case .giphy:
            return appState.appSettings.allowGiphy
        case .tenor:
            return appState.appSettings.allowTenor
        case .flickr:
            return appState.appSettings.allowFlickr
        }
    }
    
    /// View shown when GIF loading fails
    @ViewBuilder
    private func gifErrorContent(error: String) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .imageScale(.medium)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("GIF Loading Failed")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.primary)
                    
                    Text(error)
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            
            HStack(spacing: 12) {
                Button("Try Again") {
                    gifError = nil
                    setupVideoIfNeeded()
                }
                .appFont(AppTextRole.caption)
                .foregroundStyle(.blue)
                
                Spacer()
                
                Button("Open Link") {
                    if let url = URL(string: external.uri.uriString()) {
                        _ = appState.urlHandler.handle(url)
                    }
                }
                .appFont(AppTextRole.caption)
                .foregroundStyle(.blue)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
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
