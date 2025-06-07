import SwiftUI
import WebKit

struct ExternalMediaWebView: UIViewRepresentable {
    let url: URL
    let shouldBlur: Bool
    @State private var isLoading = true
    @State private var hasError = false
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        
        // Configure for embedded content
        let configuration = webView.configuration
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: ExternalMediaWebView
        
        init(_ parent: ExternalMediaWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.hasError = false
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.hasError = true
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only allow initial load and iframe content
            if navigationAction.navigationType == .other || navigationAction.targetFrame?.isMainFrame == false {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

struct EmbeddedMediaWebView: View {
    let url: URL
    let embedType: ExternalMediaType
    let shouldBlur: Bool
    @State private var isBlurred: Bool
    @State private var isLoading = true
    @State private var hasError = false
    
    init(url: URL, embedType: ExternalMediaType, shouldBlur: Bool) {
        self.url = url
        self.embedType = embedType
        self.shouldBlur = shouldBlur
        self._isBlurred = State(initialValue: shouldBlur)
    }
    
    var body: some View {
        ZStack {
            if hasError {
                errorView
            } else {
                webViewContent
                    .blur(radius: isBlurred ? 60 : 0)
                    .overlay(
                        Group {
                            if shouldBlur {
                                blurOverlay
                            }
                        }
                    )
            }
            
            if isLoading {
                loadingView
            }
        }
        .frame(height: embedHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    private var webViewContent: some View {
        ExternalMediaWebView(url: embedURL, shouldBlur: shouldBlur)
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("WebViewLoaded"))) { _ in
                isLoading = false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("WebViewError"))) { _ in
                hasError = true
                isLoading = false
            }
    }
    
    private var embedURL: URL {
        switch embedType {
        case .youtube(let videoId):
            return URL(string: "https://www.youtube.com/embed/\(videoId)?autoplay=0&modestbranding=1&rel=0")!
        case .youtubeShorts(let videoId):
            return URL(string: "https://www.youtube.com/embed/\(videoId)?autoplay=0&modestbranding=1&rel=0")!
        case .vimeo(let videoId):
            return URL(string: "https://player.vimeo.com/video/\(videoId)")!
        case .twitch(let channelOrVideo):
            if channelOrVideo.contains("videos/") {
                let videoId = channelOrVideo.replacingOccurrences(of: "videos/", with: "")
                return URL(string: "https://player.twitch.tv/?video=\(videoId)&parent=catbird.app")!
            } else {
                return URL(string: "https://player.twitch.tv/?channel=\(channelOrVideo)&parent=catbird.app")!
            }
        case .spotify(let contentType, let contentId):
            return URL(string: "https://open.spotify.com/embed/\(contentType.rawValue)/\(contentId)")!
        case .appleMusic(let contentType, let contentId):
            // Apple Music uses MusicKit embeds
            return URL(string: "https://embed.music.apple.com/\(contentType.rawValue)/\(contentId)")!
        case .soundcloud(let trackUrl):
            let encodedUrl = trackUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            return URL(string: "https://w.soundcloud.com/player/?url=\(encodedUrl)&auto_play=false&hide_related=true&show_comments=false&show_user=true&show_reposts=false")!
        case .giphy(let gifId):
            return URL(string: "https://giphy.com/embed/\(gifId)")!
        case .tenor(let gifId):
            return URL(string: "https://tenor.com/embed/\(gifId)")!
        case .flickr(let photoId):
            return URL(string: "https://live.staticflickr.com/embed/\(photoId)")!
        }
    }
    
    private var embedHeight: CGFloat {
        switch embedType {
        case .youtube, .youtubeShorts, .vimeo:
            return 200 // 16:9 aspect ratio for videos
        case .twitch:
            return 250 // Slightly taller for Twitch chat
        case .spotify, .appleMusic, .soundcloud:
            return 152 // Music player height
        case .giphy, .tenor:
            return 300 // GIF display height
        case .flickr:
            return 350 // Photo display height
        }
    }
    
    @ViewBuilder
    private var blurOverlay: some View {
        if isBlurred {
            ZStack {
                Color.black.opacity(0.3)
                
                VStack(spacing: 8) {
                    Image(systemName: "eye.slash.fill")
                        .foregroundColor(.white)
                        .font(.title2)
                    
                    Text("Sensitive Content")
                        .foregroundColor(.white)
                        .font(.headline)
                    
                    Button("Show") {
                        withAnimation {
                            isBlurred = false
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .onTapGesture {
                withAnimation {
                    isBlurred = false
                }
            }
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading embed...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.1))
    }
    
    private var errorView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
                .font(.title2)
            
            Text("Failed to load embed")
                .font(.headline)
                .foregroundColor(.primary)
            
            Text("Tap to open in browser")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.1))
        .onTapGesture {
            UIApplication.shared.open(url)
        }
    }
}

enum ExternalMediaType {
    case youtube(videoId: String)
    case youtubeShorts(videoId: String)
    case vimeo(videoId: String)
    case twitch(channelOrVideo: String)
    case spotify(contentType: SpotifyContentType, contentId: String)
    case appleMusic(contentType: AppleMusicContentType, contentId: String)
    case soundcloud(trackUrl: String)
    case giphy(gifId: String)
    case tenor(gifId: String)
    case flickr(photoId: String)
    
    enum SpotifyContentType: String {
        case track, album, playlist, artist, show, episode
    }
    
    enum AppleMusicContentType: String {
        case song, album, playlist, artist
    }
    
    static func detect(from url: URL) -> ExternalMediaType? {
        let host = url.host?.lowercased() ?? ""
        let path = url.path
        
        if host.contains("youtube.com") || host.contains("youtu.be") {
            if let videoId = extractYouTubeVideoId(from: url) {
                if path.contains("/shorts/") {
                    return .youtubeShorts(videoId: videoId)
                } else {
                    return .youtube(videoId: videoId)
                }
            }
        } else if host.contains("vimeo.com") {
            if let videoId = extractVimeoVideoId(from: url) {
                return .vimeo(videoId: videoId)
            }
        } else if host.contains("twitch.tv") {
            if let channelOrVideo = extractTwitchInfo(from: url) {
                return .twitch(channelOrVideo: channelOrVideo)
            }
        } else if host.contains("spotify.com") {
            if let (contentType, contentId) = extractSpotifyContent(from: url) {
                return .spotify(contentType: contentType, contentId: contentId)
            }
        } else if host.contains("music.apple.com") {
            if let (contentType, contentId) = extractAppleMusicContent(from: url) {
                return .appleMusic(contentType: contentType, contentId: contentId)
            }
        } else if host.contains("soundcloud.com") {
            return .soundcloud(trackUrl: url.absoluteString)
        } else if host.contains("giphy.com") {
            if let gifId = extractGiphyId(from: url) {
                return .giphy(gifId: gifId)
            }
        } else if host.contains("tenor.com") {
            if let gifId = extractTenorId(from: url) {
                return .tenor(gifId: gifId)
            }
        } else if host.contains("flickr.com") {
            if let photoId = extractFlickrId(from: url) {
                return .flickr(photoId: photoId)
            }
        }
        
        return nil
    }
    
    private static func extractYouTubeVideoId(from url: URL) -> String? {
        let urlString = url.absoluteString
        
        // Standard YouTube URL
        if let range = urlString.range(of: "v=") {
            let startIndex = range.upperBound
            let endIndex = urlString.firstIndex(of: "&") ?? urlString.endIndex
            return String(urlString[startIndex..<endIndex])
        }
        
        // YouTube Shorts URL
        if let range = urlString.range(of: "/shorts/") {
            let startIndex = range.upperBound
            let endIndex = urlString.firstIndex(of: "?") ?? urlString.endIndex
            return String(urlString[startIndex..<endIndex])
        }
        
        // youtu.be URL
        if url.host?.contains("youtu.be") == true {
            return String(url.path.dropFirst()) // Remove leading slash
        }
        
        return nil
    }
    
    private static func extractVimeoVideoId(from url: URL) -> String? {
        let pathComponents = url.pathComponents
        for component in pathComponents {
            if component.allSatisfy({ $0.isNumber }) && component.count > 3 {
                return component
            }
        }
        return nil
    }
    
    private static func extractTwitchInfo(from url: URL) -> String? {
        let path = url.path
        if path.contains("/videos/") {
            return path.replacingOccurrences(of: "/", with: "")
        } else {
            // Extract channel name
            let pathComponents = url.pathComponents.filter { !$0.isEmpty && $0 != "/" }
            return pathComponents.first
        }
    }
    
    private static func extractSpotifyContent(from url: URL) -> (SpotifyContentType, String)? {
        let components = url.pathComponents
        
        for (index, component) in components.enumerated() {
            if let contentType = SpotifyContentType(rawValue: component),
               index + 1 < components.count {
                let contentId = components[index + 1].split(separator: "?").first.map(String.init) ?? components[index + 1]
                return (contentType, contentId)
            }
        }
        return nil
    }
    
    private static func extractAppleMusicContent(from url: URL) -> (AppleMusicContentType, String)? {
        let components = url.pathComponents
        
        // Apple Music URLs: https://music.apple.com/us/song/song-name/id123456789
        for (index, component) in components.enumerated() {
            if let contentType = AppleMusicContentType(rawValue: component),
               index + 2 < components.count {
                let contentId = components[index + 2].replacingOccurrences(of: "id", with: "")
                return (contentType, contentId)
            }
        }
        return nil
    }
    
    private static func extractGiphyId(from url: URL) -> String? {
        let path = url.path
        
        // GIPHY URLs: https://giphy.com/gifs/gif-name-ABC123
        // or https://media.giphy.com/media/ABC123/giphy.gif
        if path.contains("/gifs/") {
            let components = path.split(separator: "/")
            return components.last?.split(separator: "-").last.map(String.init)
        } else if path.contains("/media/") {
            let components = path.split(separator: "/")
            if let mediaIndex = components.firstIndex(of: "media"),
               mediaIndex + 1 < components.count {
                return String(components[mediaIndex + 1])
            }
        }
        return nil
    }
    
    private static func extractTenorId(from url: URL) -> String? {
        let path = url.path
        
        // Tenor URLs: https://tenor.com/view/gif-name-123456789
        // or https://media.tenor.com/ABC123/video.mp4
        if path.contains("/view/") {
            let components = path.split(separator: "/")
            return components.last?.split(separator: "-").last.map(String.init)
        } else if path.contains("media.tenor.com") {
            let components = path.split(separator: "/")
            return components.first.map(String.init)
        }
        return nil
    }
    
    private static func extractFlickrId(from url: URL) -> String? {
        let path = url.path
        
        // Flickr URLs: https://www.flickr.com/photos/username/123456789/
        // or https://flic.kr/p/ABC123
        if path.contains("/photos/") {
            let components = path.split(separator: "/")
            if let photosIndex = components.firstIndex(of: "photos"),
               photosIndex + 2 < components.count {
                return String(components[photosIndex + 2])
            }
        } else if url.host?.contains("flic.kr") == true {
            let components = path.split(separator: "/")
            return components.last.map(String.init)
        }
        return nil
    }
    
    // Legacy method for compatibility
    private static func extractSpotifyTrackId(from url: URL) -> String? {
        if let (contentType, contentId) = extractSpotifyContent(from: url),
           contentType == .track {
            return contentId
        }
        return nil
    }
}