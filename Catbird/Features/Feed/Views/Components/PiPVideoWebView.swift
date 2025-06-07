import SwiftUI
import WebKit
import AVKit

// MARK: - PiP Manager

@Observable
class PiPManager {
    static let shared = PiPManager()
    
    var isPiPActive: Bool = false
    var currentPiPViewId: String?
    var pipFrame: CGRect = CGRect(x: 20, y: 100, width: 200, height: 112)
    
    private init() {}
    
    func startPiP(withId viewId: String) {
        currentPiPViewId = viewId
        isPiPActive = true
    }
    
    func stopPiP() {
        currentPiPViewId = nil
        isPiPActive = false
    }
}

// MARK: - PiP Video WebView

struct PiPVideoWebView: UIViewRepresentable {
    let url: URL
    let embedType: ExternalMediaType
    let shouldBlur: Bool
    let viewId: String = UUID().uuidString
    @State private var isLoading = true
    @State private var hasError = false
    @State private var isInPiP = false
    @Environment(\.dismiss) private var dismiss
    
    // PiP gesture state
    @State private var dragOffset: CGSize = .zero
    @State private var lastDragPosition: CGSize = .zero
    
    var isPiPSupported: Bool {
        switch embedType {
        case .youtube, .youtubeShorts, .vimeo, .twitch:
            return true
        default:
            return false
        }
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = UIColor.clear
        
        // Configure for embedded content with PiP support
        let configuration = webView.configuration
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        
        // Add JavaScript for PiP control
        let pipScript = """
        // Function to enable PiP for video elements
        function enablePiP() {
            const videos = document.querySelectorAll('video');
            videos.forEach(video => {
                if (video.webkitSupportsPresentationMode && 
                    video.webkitSupportsPresentationMode('picture-in-picture')) {
                    video.setAttribute('playsinline', '');
                    video.addEventListener('loadedmetadata', () => {
                        if (video.videoWidth > 0 && video.videoHeight > 0) {
                            window.webkit.messageHandlers.pipHandler.postMessage('ready');
                        }
                    });
                }
            });
        }
        
        // Function to start PiP
        function startPiP() {
            const videos = document.querySelectorAll('video');
            if (videos.length > 0) {
                const video = videos[0];
                if (video.webkitSupportsPresentationMode('picture-in-picture')) {
                    video.webkitSetPresentationMode('picture-in-picture');
                    return true;
                }
            }
            return false;
        }
        
        // Function to exit PiP
        function exitPiP() {
            const videos = document.querySelectorAll('video');
            if (videos.length > 0) {
                const video = videos[0];
                if (video.webkitPresentationMode === 'picture-in-picture') {
                    video.webkitSetPresentationMode('inline');
                    return true;
                }
            }
            return false;
        }
        
        // Initialize when page loads
        document.addEventListener('DOMContentLoaded', enablePiP);
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', enablePiP);
        } else {
            enablePiP();
        }
        """
        
        let userScript = WKUserScript(source: pipScript, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        configuration.userContentController.addUserScript(userScript)
        configuration.userContentController.add(context.coordinator, name: "pipHandler")
        
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
    
    // PiP Control Methods
    func enterPiP() {
        guard isPiPSupported else { return }
        PiPManager.shared.startPiP(withId: viewId)
        isInPiP = true
    }
    
    func exitPiP() {
        isInPiP = false
        if PiPManager.shared.currentPiPViewId == viewId {
            PiPManager.shared.stopPiP()
        }
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let parent: PiPVideoWebView
        
        init(_ parent: PiPVideoWebView) {
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
        
        // Handle PiP messages from JavaScript
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "pipHandler" {
                // Video is ready for PiP
            }
        }
    }
}

// MARK: - Enhanced Embedded Media WebView with PiP

struct EnhancedEmbeddedMediaWebView: View {
    let url: URL
    let embedType: ExternalMediaType
    let shouldBlur: Bool
    @State private var isBlurred: Bool
    @State private var isLoading = true
    @State private var hasError = false
    @State private var showControls = false
    @State private var controlsTimer: Timer?
    
    // PiP state
    @State private var isInPiP = false
    @State private var pipWebView: PiPVideoWebView?
    
    @Environment(AppState.self) private var appState
    
    init(url: URL, embedType: ExternalMediaType, shouldBlur: Bool) {
        self.url = url
        self.embedType = embedType
        self.shouldBlur = shouldBlur
        self._isBlurred = State(initialValue: shouldBlur)
    }
    
    var isPiPSupported: Bool {
        switch embedType {
        case .youtube, .youtubeShorts, .vimeo, .twitch:
            return true
        default:
            return false
        }
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
                    .overlay(
                        Group {
                            if isPiPSupported && !isBlurred {
                                videoControlsOverlay
                            }
                        }
                    )
                    .onTapGesture {
                        if isPiPSupported && !isBlurred {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showControls.toggle()
                            }
                            resetControlsTimer()
                        }
                    }
            }
            
            if isLoading {
                loadingView
            }
        }
        .frame(height: embedHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if isPiPSupported {
                pipWebView = PiPVideoWebView(url: embedURL, embedType: embedType, shouldBlur: shouldBlur)
            }
        }
    }
    
    @ViewBuilder
    private var webViewContent: some View {
        if let pipWebView = pipWebView {
            pipWebView
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("WebViewLoaded"))) { _ in
                    isLoading = false
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("WebViewError"))) { _ in
                    hasError = true
                    isLoading = false
                }
        } else {
            ExternalMediaWebView(url: embedURL, shouldBlur: shouldBlur)
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("WebViewLoaded"))) { _ in
                    isLoading = false
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("WebViewError"))) { _ in
                    hasError = true
                    isLoading = false
                }
        }
    }
    
    @ViewBuilder
    private var videoControlsOverlay: some View {
        if showControls && appState.appSettings.enablePictureInPicture {
            VStack {
                HStack {
                    Spacer()
                    
                    // PiP Button
                    Button(action: {
                        if isInPiP {
                            pipWebView?.exitPiP()
                            isInPiP = false
                        } else {
                            pipWebView?.enterPiP()
                            isInPiP = true
                        }
                        showControls = false
                    }) {
                        Image(systemName: isInPiP ? "pip.exit" : "pip.enter")
                            .foregroundColor(.white)
                            .font(.title2)
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 8)
                }
                
                Spacer()
                
                // Bottom controls
                HStack {
                    Button(action: {
                        // Fullscreen action
                        showControls = false
                    }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .foregroundColor(.white)
                            .font(.title3)
                            .padding(6)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        // Share action
                        showControls = false
                    }) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.white)
                            .font(.title3)
                            .padding(6)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
                .padding(.bottom, 8)
                .padding(.horizontal, 8)
            }
            .transition(.opacity)
            .onAppear {
                resetControlsTimer()
            }
        }
    }
    
    private func resetControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                showControls = false
            }
        }
    }
    
    private var embedURL: URL {
        switch embedType {
        case .youtube(let videoId):
            return URL(string: "https://www.youtube.com/embed/\(videoId)?autoplay=0&modestbranding=1&rel=0&playsinline=1")!
        case .youtubeShorts(let videoId):
            return URL(string: "https://www.youtube.com/embed/\(videoId)?autoplay=0&modestbranding=1&rel=0&playsinline=1")!
        case .vimeo(let videoId):
            return URL(string: "https://player.vimeo.com/video/\(videoId)?playsinline=1")!
        case .twitch(let channelOrVideo):
            if channelOrVideo.contains("videos/") {
                let videoId = channelOrVideo.replacingOccurrences(of: "videos/", with: "")
                return URL(string: "https://player.twitch.tv/?video=\(videoId)&parent=catbird.app&playsinline=1")!
            } else {
                return URL(string: "https://player.twitch.tv/?channel=\(channelOrVideo)&parent=catbird.app&playsinline=1")!
            }
        case .spotify(let contentType, let contentId):
            return URL(string: "https://open.spotify.com/embed/\(contentType.rawValue)/\(contentId)")!
        case .appleMusic(let contentType, let contentId):
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

