import SwiftUI
import WebKit
import AVKit

// MARK: - Web PiP Manager (Legacy - use EnhancedPiPManager for new implementations)

@Observable
class PiPManager {
    static let shared = PiPManager()
    
    var isPiPActive: Bool = false
    var currentPiPViewId: String?
    var pipFrame: CGRect = CGRect(x: 20, y: 100, width: 200, height: 112)
    
    private init() {}
    
    func startPiP(withId viewId: String) {
        // Coordinate with the enhanced PiP manager
        EnhancedPiPManager.shared.startPiP(withVideoId: viewId)
        currentPiPViewId = viewId
        isPiPActive = true
    }
    
    func stopPiP() {
        // Coordinate with the enhanced PiP manager
        EnhancedPiPManager.shared.stopPiP()
        currentPiPViewId = nil
        isPiPActive = false
    }
}

// MARK: - PiP Video WebView

struct PiPVideoWebView: UIViewRepresentable, Equatable {
    let url: URL
    let embedType: ExternalMediaType
    let shouldBlur: Bool
    let viewId: String = UUID().uuidString
    @Binding var isLoading: Bool
    @Binding var hasError: Bool
    @State private var isInPiP = false
    @Environment(\.dismiss) private var dismiss
    
    // PiP gesture state
    @State private var dragOffset: CGSize = .zero
    @State private var lastDragPosition: CGSize = .zero
    
    // Add equatable conformance to prevent unnecessary recreation
    static func == (lhs: PiPVideoWebView, rhs: PiPVideoWebView) -> Bool {
        return lhs.url == rhs.url && lhs.embedType == rhs.embedType && lhs.shouldBlur == rhs.shouldBlur
    }
    
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
        
        // Enhanced JavaScript for PiP control with better platform detection
        let pipScript = """
        // Enhanced PiP support with fallback detection
        let pipController = null;
        let currentVideo = null;
        
        // Function to enable PiP for video elements
        function enablePiP() {
            const videos = document.querySelectorAll('video');
            videos.forEach((video, index) => {
                // Set attributes for better iOS compatibility
                video.setAttribute('playsinline', '');
                video.setAttribute('webkit-playsinline', '');
                video.setAttribute('controls', '');
                
                // Listen for video ready events
                video.addEventListener('loadedmetadata', () => {
                    if (video.videoWidth > 0 && video.videoHeight > 0) {
                        currentVideo = video;
                        
                        // Check for native PiP support
                        if (video.webkitSupportsPresentationMode && 
                            video.webkitSupportsPresentationMode('picture-in-picture')) {
                            
                            window.webkit.messageHandlers.pipHandler.postMessage({
                                type: 'ready',
                                supportsNativePiP: true,
                                videoIndex: index
                            });
                            
                            // Add PiP event listeners
                            video.addEventListener('webkitpresentationmodechanged', (e) => {
                                const mode = e.target.webkitPresentationMode;
                                window.webkit.messageHandlers.pipHandler.postMessage({
                                    type: 'presentationModeChanged',
                                    mode: mode,
                                    videoIndex: index
                                });
                            });
                        } else {
                            // Check for newer API
                            if ('pictureInPictureEnabled' in document) {
                                video.addEventListener('enterpictureinpicture', () => {
                                    window.webkit.messageHandlers.pipHandler.postMessage({
                                        type: 'pipEntered',
                                        videoIndex: index
                                    });
                                });
                                
                                video.addEventListener('leavepictureinpicture', () => {
                                    window.webkit.messageHandlers.pipHandler.postMessage({
                                        type: 'pipExited',
                                        videoIndex: index
                                    });
                                });
                            }
                            
                            window.webkit.messageHandlers.pipHandler.postMessage({
                                type: 'ready',
                                supportsNativePiP: false,
                                videoIndex: index
                            });
                        }
                    }
                });
                
                // Also check if video is already loaded
                if (video.readyState >= 1) {
                    video.dispatchEvent(new Event('loadedmetadata'));
                }
            });
        }
        
        // Function to start PiP with enhanced error handling
        function startPiP() {
            if (!currentVideo) {
                const videos = document.querySelectorAll('video');
                if (videos.length > 0) {
                    currentVideo = videos[0];
                }
            }
            
            if (currentVideo) {
                try {
                    // Try webkit API first (iOS Safari)
                    if (currentVideo.webkitSupportsPresentationMode && 
                        currentVideo.webkitSupportsPresentationMode('picture-in-picture')) {
                        currentVideo.webkitSetPresentationMode('picture-in-picture');
                        return true;
                    }
                    
                    // Try standard API (other browsers)
                    if (currentVideo.requestPictureInPicture) {
                        currentVideo.requestPictureInPicture().then(() => {
                            window.webkit.messageHandlers.pipHandler.postMessage({
                                type: 'pipStarted'
                            });
                        }).catch((error) => {
                            window.webkit.messageHandlers.pipHandler.postMessage({
                                type: 'pipError',
                                error: error.message
                            });
                        });
                        return true;
                    }
                } catch (error) {
                    window.webkit.messageHandlers.pipHandler.postMessage({
                        type: 'pipError',
                        error: error.message
                    });
                }
            }
            return false;
        }
        
        // Function to exit PiP
        function exitPiP() {
            if (currentVideo) {
                try {
                    // Try webkit API
                    if (currentVideo.webkitPresentationMode === 'picture-in-picture') {
                        currentVideo.webkitSetPresentationMode('inline');
                        return true;
                    }
                    
                    // Try standard API
                    if (document.pictureInPictureElement === currentVideo) {
                        document.exitPictureInPicture();
                        return true;
                    }
                } catch (error) {
                    window.webkit.messageHandlers.pipHandler.postMessage({
                        type: 'pipError',
                        error: error.message
                    });
                }
            }
            return false;
        }
        
        // Function to check if PiP is currently active
        function isPiPActive() {
            if (currentVideo) {
                return currentVideo.webkitPresentationMode === 'picture-in-picture' ||
                       document.pictureInPictureElement === currentVideo;
            }
            return false;
        }
        
        // Initialize when page loads with multiple checks
        function initializePiP() {
            enablePiP();
            // Also try again after a short delay for dynamic content
            setTimeout(enablePiP, 1000);
            setTimeout(enablePiP, 3000);
        }
        
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', initializePiP);
        } else {
            initializePiP();
        }
        
        // Re-check for new videos periodically (for dynamic content)
        setInterval(enablePiP, 5000);
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
    
    // Helper method to access the underlying WKWebView
    func getUIView() -> WKWebView? {
        // This is a workaround - in practice you'd need to store a reference
        // For now, this will be handled by the JavaScript calls
        return nil
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let parent: PiPVideoWebView
        
        init(_ parent: PiPVideoWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = true
                self.parent.hasError = false
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.hasError = false
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.hasError = true
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.hasError = true
            }
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow all embed content and user interactions within the frame
            if navigationAction.targetFrame?.isMainFrame == false {
                // Always allow iframe content (embeds)
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .other {
                // Allow initial load and programmatic navigation
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .linkActivated {
                // Handle external link clicks by opening in Safari
                if let url = navigationAction.request.url {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
            } else {
                // Allow other types of navigation (like user interactions within embeds)
                decisionHandler(.allow)
            }
        }
        
        // Handle PiP messages from JavaScript
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "pipHandler" {
                guard let messageBody = message.body as? [String: Any],
                      let messageType = messageBody["type"] as? String else {
                    return
                }
                
                DispatchQueue.main.async {
                    switch messageType {
                    case "ready":
                        let supportsNativePiP = messageBody["supportsNativePiP"] as? Bool ?? false
                        // Video is ready for PiP - could update UI here
                        print("📺 WebView video ready for PiP, native support: \(supportsNativePiP)")
                        
                    case "presentationModeChanged":
                        let mode = messageBody["mode"] as? String ?? ""
                        if mode == "picture-in-picture" {
                            self.parent.enterPiP()
                        } else if mode == "inline" {
                            self.parent.exitPiP()
                        }
                        
                    case "pipEntered":
                        self.parent.enterPiP()
                        
                    case "pipExited":
                        self.parent.exitPiP()
                        
                    case "pipStarted":
                        self.parent.enterPiP()
                        
                    case "pipError":
                        let error = messageBody["error"] as? String ?? "Unknown error"
                        print("❌ WebView PiP error: \(error)")
                        
                    default:
                        break
                    }
                }
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
    @State private var hasLoadedOnce = false
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
            
            if isLoading && !hasLoadedOnce {
                loadingView
            }
        }
        .frame(height: embedHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if isPiPSupported {
                pipWebView = PiPVideoWebView(
                    url: embedURL, 
                    embedType: embedType, 
                    shouldBlur: shouldBlur,
                    isLoading: $isLoading,
                    hasError: $hasError
                )
            }
        }
        .onChange(of: isLoading) { _, newValue in
            if !newValue && !hasError {
                hasLoadedOnce = true
            }
        }
    }
    
    @ViewBuilder
    private var webViewContent: some View {
        if let pipWebView = pipWebView {
            pipWebView
                .id(embedURL.absoluteString) // Stable identity
        } else {
            ExternalMediaWebView(
                url: embedURL, 
                shouldBlur: shouldBlur,
                isLoading: $isLoading,
                hasError: $hasError
            )
            .id(embedURL.absoluteString) // Stable identity
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
                            // JavaScript will handle state change via message handler
                        } else {
                            // Start custom PiP for web embeds
                            pipWebView?.enterPiP()
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
                .scaleEffect(0.8)
                .progressViewStyle(CircularProgressViewStyle(tint: .secondary))
            Text("Loading...")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color(UIColor.systemBackground).opacity(0.9))
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
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
