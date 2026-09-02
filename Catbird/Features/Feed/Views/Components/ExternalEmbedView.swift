import SwiftUI
import NukeUI
import Petrel
import WebKit
import os.log

/// Bounded success-only cache for validated derived MP4 URLs.
private final class DerivedMP4ValidationCache: @unchecked Sendable {
    static let shared = DerivedMP4ValidationCache()
    private let cache = NSCache<NSURL, NSNumber>()

    private init() {
        cache.countLimit = 256
    }

    func isValidated(_ url: URL) -> Bool {
        cache.object(forKey: url as NSURL) != nil
    }

    func setValidated(_ url: URL) {
        cache.setObject(NSNumber(value: true), forKey: url as NSURL)
    }
}

struct ExternalEmbedView: View {
    let external: AppBskyEmbedExternal.ViewExternal
    let shouldBlur: Bool
    let postID: String
    @State private var isBlurred: Bool
    @State private var userTappedToShowEmbed = false
    @State private var showingConsentDialog = false
    @State private var pendingConsentProvider: ExternalMediaProvider?
    @Environment(\.appSettings) private var appSettings
    @ObservationIgnored @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @State private var videoModel: VideoModel?
    @State private var gifError: String?
    @State private var isLoadingGif: Bool = false
    @State private var gifAspectRatio: CGFloat = 1.0
    /// URL for a Klipy GIF that has no derivable MP4 (e.g. legacy posts whose
    /// embed URI is a .gif). Rendered inline as a static image so it doesn't
    /// fall back to the link card.
    @State private var inlineImageURL: URL?
    @State private var retryAttempt: Int = 0

    private struct ValidationIdentity: Hashable {
        let url: URL?
        let isAllowed: Bool
        let attempt: Int
    }
    
    private let logger = Logger(subsystem: "blue.catbird", category: "ExternalEmbedView")

    /// Whether external media consent is explicitly allowed for this GIF provider
    private var isGifProviderAllowed: Bool {
        guard let url = destinationURL, isGifURL else { return false }
        guard let provider = provider(for: url) else { return false }
        return appSettings.externalMediaConsent(for: provider) == .allow
    }

    /// Whether this external embed URL is a known GIF host (Tenor/Giphy/Klipy)
    private var isGifURL: Bool {
        guard let url = destinationURL else { return false }
        return Self.isGifHost(url)
    }

    private static func isGifHost(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "media.tenor.com"
            || host.contains("tenor.com")
            || host.contains("giphy.com")
            || host.contains("media.giphy.com")
            || host == "static.klipy.com"
            || host.contains("klipy.com")
    }

    private func provider(for url: URL) -> ExternalMediaProvider? {
        if let embedType = ExternalMediaType.detect(from: url) {
            return embedType.provider
        }
        let host = url.host?.lowercased() ?? ""
        if host == "media.tenor.com" || host.contains("tenor.com") {
            return .tenor
        }
        if host.contains("giphy.com") {
            return .giphy
        }
        if host == "static.klipy.com" || host.contains("klipy.com") {
            return .klipy
        }
        if host.contains("youtube.com") || host.contains("youtu.be") {
            return host.contains("shorts") ? .youtubeShorts : .youtube
        }
        if host.contains("vimeo.com") {
            return .vimeo
        }
        if host.contains("twitch.tv") {
            return .twitch
        }
        if host.contains("spotify.com") {
            return .spotify
        }
        if host.contains("music.apple.com") {
            return .appleMusic
        }
        if host.contains("soundcloud.com") {
            return .soundcloud
        }
        if host.contains("flickr.com") || host.contains("flic.kr") {
            return .flickr
        }
        if host.contains("bandcamp.com") {
            return .bandcamp
        }
        return nil
    }
    init(external: AppBskyEmbedExternal.ViewExternal, shouldBlur: Bool, postID: String) {
        self.external = external
        self.shouldBlur = shouldBlur
        self._isBlurred = State(initialValue: shouldBlur)
        self.postID = postID

        // Compute the GIF aspect-ratio hint synchronously (from the record's own
        // hh=/ww= query params, where present) so the very first render already
        // reserves the correct height. Deriving this reactively in onAppear (the old
        // behavior) meant the first layout pass always showed the small link-card,
        // then snapped to a much taller placeholder one frame later once onAppear
        // fired — the reported overlap-then-jump. Giphy URLs carry no such params,
        // so they still start at the 1.0 default and refine once the video loads —
        // a much smaller residual than the old card-to-placeholder swap.
        let url = external.uri.url ?? URL(string: external.uri.uriString())
        if let url, Self.isGifHost(url) {
            self._gifAspectRatio = State(initialValue: Self.tenorAspectRatioHint(from: url) ?? 1.0)
        } else {
            self._gifAspectRatio = State(initialValue: 1.0)
        }
    }

    private var destinationURL: URL? {
        external.uri.url ?? URL(string: external.uri.uriString())
    }
    
    var body: some View {
        Group {
            if shouldShowExternalEmbed(for: external.uri) {
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
                .task(id: ValidationIdentity(url: destinationURL, isAllowed: isGifProviderAllowed, attempt: retryAttempt)) {
                    await setupVideo()
                }
                // Fixed sizing to prevent layout jumps
                .fixedSize(horizontal: false, vertical: true)
            } else {
                blockedExternalMediaView
            }
        }
        .confirmationDialog(
            "Enable \(pendingConsentProvider?.displayName ?? "External Media")?",
            isPresented: $showingConsentDialog,
            titleVisibility: .visible,
            presenting: pendingConsentProvider
        ) { provider in
            Button("Enable external media") {
                appState.appSettings.setExternalMediaConsentForAllProviders(.allow)
                withAnimation(.easeInOut(duration: 0.3)) {
                    userTappedToShowEmbed = true
                }
                retryAttempt += 1
            }
            Button("Enable \(provider.displayName) only") {
                appState.appSettings.setExternalMediaConsent(.allow, for: provider)
                withAnimation(.easeInOut(duration: 0.3)) {
                    userTappedToShowEmbed = true
                }
                retryAttempt += 1
            }
            Button("No thanks", role: .cancel) {
                appState.appSettings.setExternalMediaConsent(.hide, for: provider)
            }
        } message: { provider in
            Text("Playing embeds connects directly to third-party servers and may share your IP address or tracking data with \(provider.displayName).")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let videoModel = videoModel {
            videoPlayerContent(videoModel: videoModel)
        } else if let gifError = gifError {
            gifErrorContent(error: gifError)
        } else if let inlineImageURL = inlineImageURL {
            inlineImageContent(url: inlineImageURL)
        } else if isGifProviderAllowed && (isLoadingGif || isGifURL) {
            // `isGifURL` (unlike `isLoadingGif`) is available on the very first
            // render, before `onAppear`/`setupVideoIfNeeded` ever runs — this is
            // what actually prevents the small link-card from ever appearing for a
            // GIF embed, instead of it flashing in and then snapping to this taller
            // placeholder one frame later.
            gifLoadingPlaceholder
        } else if let url = destinationURL,
                  appSettings.useWebViewEmbeds,
                  userTappedToShowEmbed,
                  let embedType = ExternalMediaType.detect(from: url),
                  shouldShowWebViewEmbed(for: embedType) {
            webViewEmbedContent(url: url, embedType: embedType)
        } else {
            linkCardContent()
        }
    }

    @ViewBuilder
    private func inlineImageContent(url: URL) -> some View {
        LazyImage(url: url) { state in
            if let image = state.image {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
            }
        }
        .aspectRatio(gifAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: PlatformScreenInfo.height * 0.6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    /// Placeholder shown while a GIF is being validated, using the thumbnail to prevent a flash to the link card
    @ViewBuilder
    private var gifLoadingPlaceholder: some View {
        ZStack {
            if let thumbURL = external.thumb?.url {
                LazyImage(url: thumbURL) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.15))
                    }
                }
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.15))
            }

            ProgressView()
        }
        .aspectRatio(gifAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: PlatformScreenInfo.height * 0.6)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    
    @ViewBuilder
    private func videoPlayerContent(videoModel: VideoModel) -> some View {
        // ContentLabelManager handles all blur logic now
        ModernVideoPlayerView(
            model: videoModel,
            postID: postID
        )
        .aspectRatio(videoModel.aspectRatio, contentMode: .fit)
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
        let detectedEmbedType: ExternalMediaType? = {
            if let url = destinationURL {
                return ExternalMediaType.detect(from: url)
            }
            return nil
        }()

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
        .contentShape(Rectangle())
        .onTapGesture {
            handleCardTap(embedType: detectedEmbedType)
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
    

    private func setupVideo() async {
        // Reset derived media state so destination changes do not keep or republish stale media
        videoModel = nil
        inlineImageURL = nil
        gifError = nil
        isLoadingGif = false

        guard !Task.isCancelled else { return }

        guard let url = destinationURL else {
            logger.debug("❌ Failed to create URL from external URI: \(external.uri.uriString())")
            return
        }
        
        // Gate all GIF setup, validation, and player branches on `.allow`
        if let provider = provider(for: url) {
            let consent = appSettings.externalMediaConsent(for: provider)
            guard consent == .allow else {
                logger.debug("⏸️ Skipping video setup for \(provider.displayName) - consent is \(consent.rawValue)")
                return
            }
        }
        
        guard !Task.isCancelled else { return }

        // Handle Tenor GIFs
        if url.host == "media.tenor.com" || url.host?.contains("tenor.com") == true {
            // Extract aspect ratio BEFORE setting loading state
            let hintedAspectRatio = Self.tenorAspectRatioHint(from: url)
            if let hintedAspectRatio {
                gifAspectRatio = hintedAspectRatio
                logger.debug("🎬 Extracted aspect ratio from URL params = \(gifAspectRatio)")
            } else {
                gifAspectRatio = 1.0
                logger.debug("🎬 Using default aspect ratio 1.0 (no valid dimensions in URL)")
            }
            
            isLoadingGif = true
            await setupTenorVideo(from: url, aspectRatio: gifAspectRatio)
        }
        // Handle Giphy GIFs
        else if url.host?.contains("giphy.com") == true {
            logger.debug("🎬 Detected Giphy GIF, attempting conversion...")

            // Set default aspect ratio for Giphy BEFORE loading state
            gifAspectRatio = 1.0

            isLoadingGif = true
            await setupGiphyVideo(from: url)
        }
        // Handle Klipy GIFs
        else if url.host == "static.klipy.com" || url.host?.contains("klipy.com") == true {
            let hintedAspectRatio = Self.tenorAspectRatioHint(from: url)
            gifAspectRatio = hintedAspectRatio ?? 1.0
            logger.debug("🎬 Detected Klipy media, aspect ratio = \(gifAspectRatio)")
            setupKlipyMedia(from: url, aspectRatio: gifAspectRatio)
        } else {
            logger.debug("ℹ️ URL is not a recognized GIF host, treating as regular external link")
        }
    }

    private static func tenorAspectRatioHint(from url: URL) -> CGFloat? {
        guard let widthStr = url.queryParameters?["ww"],
              let heightStr = url.queryParameters?["hh"],
              let width = Double(widthStr),
              let height = Double(heightStr),
              width > 0, height > 0 else {
            return nil
        }

        let ratio = CGFloat(width / height)
        guard ratio.isFinite, ratio > 0 else { return nil }
        return ratio
    }
    
    private func setupTenorVideo(from url: URL, aspectRatio: CGFloat) async {
        guard !Task.isCancelled else { return }
        logger.debug("🎬 Setting up Tenor video from URL: \(url.absoluteString)")

        // Transform Tenor URL to direct MP4 URL
        let pathComponents = url.path.split(separator: "/")
        logger.debug("🎬 Tenor URL path components: \(pathComponents)")

        if let idComponent = pathComponents.first {
            let videoId = String(idComponent).replacingOccurrences(of: "AAAAC", with: "AAAPo")
            logger.debug("🎬 Transformed Tenor ID: '\(idComponent)' -> '\(videoId)'")

            if let mp4URL = URL(string: "https://media.tenor.com/\(videoId)/video.mp4") {
                logger.debug("✅ Created Tenor MP4 URL: \(mp4URL.absoluteString)")
                await validateAndCreateTenorModel(
                    mp4URL: mp4URL,
                    aspectRatio: aspectRatio,
                    originalURL: url
                )
            } else {
                logger.debug("❌ Failed to create MP4 URL for Tenor video ID: \(videoId)")
                guard !Task.isCancelled else { return }
                isLoadingGif = false
                gifError = "Failed to create MP4 URL"
            }
        } else {
            logger.debug("❌ No path components found in Tenor URL: \(url.path)")
            guard !Task.isCancelled else { return }
            isLoadingGif = false
            gifError = "Failed to parse Tenor GIF URL"
        }
    }
    
    private func validateAndCreateTenorModel(
        mp4URL: URL,
        aspectRatio: CGFloat,
        originalURL: URL
    ) async {
        guard !Task.isCancelled else { return }

        if DerivedMP4ValidationCache.shared.isValidated(mp4URL) {
            guard !Task.isCancelled else { return }
            let model = VideoModel(
                id: "\(postID)-tenor-\(originalURL.absoluteString)",
                url: mp4URL,
                type: .tenorGif(external.uri),
                aspectRatio: aspectRatio,
                thumbnailURL: external.thumb?.url
            )
            guard !Task.isCancelled else { return }
            videoModel = model
            isLoadingGif = false
            gifError = nil
            logger.debug("✅ Used cached validation for Tenor GIF: \(model.id)")
            return
        }

        do {
            var request = URLRequest(url: mp4URL)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5.0

            let (_, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return }

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    DerivedMP4ValidationCache.shared.setValidated(mp4URL)
                    guard !Task.isCancelled else { return }
                    let model = VideoModel(
                        id: "\(postID)-tenor-\(originalURL.absoluteString)",
                        url: mp4URL,
                        type: .tenorGif(external.uri),
                        aspectRatio: aspectRatio,
                        thumbnailURL: external.thumb?.url
                    )
                    videoModel = model
                    isLoadingGif = false
                    gifError = nil
                    logger.debug("✅ Created VideoModel for Tenor GIF: \(model.id)")
                } else {
                    logger.debug("❌ Tenor MP4 URL returned status \(httpResponse.statusCode): \(mp4URL.absoluteString)")
                    guard !Task.isCancelled else { return }
                    isLoadingGif = false
                    gifError = "MP4 conversion failed (status \(httpResponse.statusCode))"
                }
            }
        } catch {
            guard !Task.isCancelled,
                  !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled
            else { return }
            logger.debug("❌ Failed to validate Tenor MP4 URL: \(error)")
            isLoadingGif = false
            gifError = "Unable to load MP4 version"
        }
    }

    
    /// Klipy's `.gif` and `.mp4` URLs share a path prefix but have unrelated
    /// per-format filenames (unlike Tenor's `AAAAC → AAAPo` swap on a single
    /// directory ID). The composer now always stores the canonical `.gif` URI
    /// (so other clients' image decoders can render it) plus an `mp4=`/`webm=`
    /// query-param slug carrying the video variant's filename — reconstruct the
    /// playable video URL by substituting that slug into the same directory.
    private func setupKlipyMedia(from url: URL, aspectRatio: CGFloat) {
        guard !Task.isCancelled else { return }
        if let mp4Slug = url.queryParameters?["mp4"], !mp4Slug.isEmpty,
           let videoURL = klipyVideoURL(from: url, filename: "\(mp4Slug).mp4") {
            let model = VideoModel(
                id: "\(postID)-klipy-\(videoURL.absoluteString)",
                url: videoURL,
                type: .tenorGif(external.uri),
                aspectRatio: aspectRatio,
                thumbnailURL: external.thumb?.url
            )
            videoModel = model
            logger.debug("✅ Created VideoModel for Klipy MP4 (from mp4= slug): \(model.id)")
            return
        }

        // Legacy fallback: posts made before the mp4=/webm= slug convention may
        // have stored the `.mp4` URL directly as external.uri — keep playing those.
        let lastPath = url.lastPathComponent.lowercased()
        if lastPath.hasSuffix(".mp4") || lastPath.hasSuffix(".m4v") {
            let model = VideoModel(
                id: "\(postID)-klipy-\(url.absoluteString)",
                url: url,
                type: .tenorGif(external.uri),
                aspectRatio: aspectRatio,
                thumbnailURL: external.thumb?.url
            )
            videoModel = model
            logger.debug("✅ Created VideoModel for Klipy MP4 (legacy direct-mp4 URI): \(model.id)")
            return
        }

        inlineImageURL = url
        logger.debug("🖼️ Klipy URI has no mp4= slug and is not itself an MP4; falling back to inline static image")
    }

    /// Rebuilds a same-directory Klipy asset URL by swapping in a different filename
    /// (e.g. the static `.gif`'s directory + the `mp4=` slug's filename).
    private func klipyVideoURL(from url: URL, filename: String) -> URL? {
        url.deletingLastPathComponent().appendingPathComponent(filename)
    }

    private func setupGiphyVideo(from url: URL) async {
        guard !Task.isCancelled else { return }
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
            guard !Task.isCancelled else { return }
            isLoadingGif = false
            gifError = "Failed to parse Giphy GIF URL"
            return
        }
        
        // Create MP4 URL for Giphy
        if let mp4URL = URL(string: "https://media.giphy.com/media/\(gifId)/giphy.mp4") {
            logger.debug("✅ Created Giphy MP4 URL: \(mp4URL.absoluteString)")
            await validateAndCreateGiphyModel(mp4URL: mp4URL, gifId: gifId)
        } else {
            logger.debug("❌ Failed to create MP4 URL for Giphy ID: \(gifId)")
            guard !Task.isCancelled else { return }
            isLoadingGif = false
            gifError = "Failed to create MP4 URL"
        }
    }
    
    private func validateAndCreateGiphyModel(mp4URL: URL, gifId: String) async {
        guard !Task.isCancelled else { return }

        if DerivedMP4ValidationCache.shared.isValidated(mp4URL) {
            guard !Task.isCancelled else { return }
            let model = VideoModel(
                id: "\(postID)-giphy-\(gifId)",
                url: mp4URL,
                type: .giphyGif(external.uri),
                aspectRatio: gifAspectRatio,
                thumbnailURL: external.thumb?.url
            )
            guard !Task.isCancelled else { return }
            videoModel = model
            isLoadingGif = false
            gifError = nil
            logger.debug("✅ Used cached validation for Giphy GIF: \(model.id)")
            return
        }

        do {
            var request = URLRequest(url: mp4URL)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5.0

            let (_, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return }

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    DerivedMP4ValidationCache.shared.setValidated(mp4URL)
                    guard !Task.isCancelled else { return }
                    let model = VideoModel(
                        id: "\(postID)-giphy-\(gifId)",
                        url: mp4URL,
                        type: .giphyGif(external.uri),
                        aspectRatio: gifAspectRatio,
                        thumbnailURL: external.thumb?.url
                    )
                    videoModel = model
                    isLoadingGif = false
                    gifError = nil
                    logger.debug("✅ Created VideoModel for Giphy GIF: \(model.id)")
                } else {
                    logger.debug("❌ Giphy MP4 URL returned status \(httpResponse.statusCode): \(mp4URL.absoluteString)")
                    guard !Task.isCancelled else { return }
                    isLoadingGif = false
                    gifError = "MP4 conversion failed (status \(httpResponse.statusCode))"
                }
            }
        } catch {
            guard !Task.isCancelled,
                  !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled
            else { return }
            logger.debug("❌ Failed to validate Giphy MP4 URL: \(error)")
            isLoadingGif = false
            gifError = "Unable to load MP4 version"
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
            if appSettings.useWebViewEmbeds,
               let url = destinationURL,
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
        case .bandcamp:
            return "Bandcamp"
        }
    }
    
    private func handleTap() {
        if isBlurred {
            // Simply remove blur when tapped while blurred
            withAnimation {
                isBlurred = false
            }
        } else if let url = destinationURL {
            // Handle URL tap when content is visible
            _ = appState.urlHandler.handle(url)
        }
    }

    private func handleCardTap(embedType: ExternalMediaType?) {
        guard let url = destinationURL else {
            logger.error("❌ External embed missing valid URL for card tap")
            return
        }
        
        let targetProvider = embedType?.provider ?? provider(for: url)
        
        if let provider = targetProvider {
            let consent = appSettings.externalMediaConsent(for: provider)
            switch consent {
            case .allow:
                if isGifURL {
                    retryAttempt += 1

                } else if appSettings.useWebViewEmbeds, let embedType = embedType ?? ExternalMediaType.detect(from: url) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        userTappedToShowEmbed = true
                    }
                } else {
                    _ = appState.urlHandler.handle(url)
                }
            case .undecided:
                pendingConsentProvider = provider
                showingConsentDialog = true
            case .hide:
                _ = appState.urlHandler.handle(url)
            }
        } else {
            _ = appState.urlHandler.handle(url)
        }
    }
    
    // MARK: - External Media Filtering
    
    /// Check if external media should be shown based on user settings
    private func shouldShowExternalEmbed(for uri: URI) -> Bool {
        guard let url = destinationURL ?? uri.url ?? URL(string: uri.uriString()),
              let provider = provider(for: url) else {
            return true
        }
        let consent = appSettings.externalMediaConsent(for: provider)
        return consent != .hide
    }
    
    /// Check if WebView embeds should be shown for specific media types
    private func shouldShowWebViewEmbed(for embedType: ExternalMediaType) -> Bool {
        let consent = appSettings.externalMediaConsent(for: embedType.provider)
        return consent == .allow
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
                    retryAttempt += 1
                }
                .appFont(AppTextRole.caption)
                .foregroundStyle(.blue)
                
                Spacer()
                
                Button("Open Link") {
                    if let url = destinationURL {
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
            Button("Settings") {
                appState.navigationManager.navigate(to: .settings(.contentAndMedia))
            }
            .appFont(AppTextRole.caption)
            .foregroundStyle(.blue)
            
            Spacer()
            
            Button("Open Link") {
                if let url = destinationURL {
                    _ = appState.urlHandler.handle(url)
                }
            }
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
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

#Preview("External Embed") {
  AsyncPreviewContent { appState in
    ExternalEmbedPreviewLoader(appState: appState)
  }
}

private struct ExternalEmbedPreviewLoader: View {
  let appState: AppState
  @State private var data: (post: AppBskyFeedDefs.PostView, external: AppBskyEmbedExternal.ViewExternal)?

  var body: some View {
    Group {
      if let data {
        ExternalEmbedView(
          external: data.external,
          shouldBlur: false,
          postID: data.post.cid.string
        )
        .padding()
      } else {
        ProgressView("Loading embed...")
      }
    }
    .task {
      data = await PreviewData.firstPostWithExternalEmbed(from: appState)
    }
  }
}
