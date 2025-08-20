//
//  iOS18EnhancedVideoPlayer.swift
//  Catbird
//
//  iOS 18 Enhanced Video Player with ProMotion, HDR, and advanced AVFoundation features
//

import SwiftUI
import AVKit
import AVFoundation
import OSLog
import Combine
import MediaPlayer
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - iOS 18 Enhanced Video Player

@available(iOS 18.0, *)
struct iOS18EnhancedVideoPlayer: View {
    let videoURL: URL
    let autoPlay: Bool
    let showControls: Bool
    let enablePiP: Bool
    
    @StateObject private var playerController: EnhancedVideoPlayerController
    @State private var isFullScreen: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var currentPlaybackSpeed: PlaybackSpeed = .normal
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    
    private let logger = Logger(subsystem: "blue.catbird", category: "iOS18VideoPlayer")
    
    init(
        videoURL: URL,
        autoPlay: Bool = false,
        showControls: Bool = true,
        enablePiP: Bool = true
    ) {
        self.videoURL = videoURL
        self.autoPlay = autoPlay
        self.showControls = showControls
        self.enablePiP = enablePiP
        self._playerController = StateObject(wrappedValue: EnhancedVideoPlayerController(url: videoURL))
    }
    
    var body: some View {
        #if os(iOS)
        GeometryReader { geometry in
            ZStack {
                // Video player view
                VideoPlayerViewRepresentable(
                    player: playerController.player,
                    showControls: showControls,
                    enablePiP: enablePiP,
                    onPlaybackStateChange: { state in
                        playerController.handlePlaybackStateChange(state)
                    }
                )
                .ignoresSafeArea()
                
                // Custom overlay controls
                if showControls && !playerController.isUsingSystemControls {
                    CustomVideoControlsOverlay(
                        playerController: playerController,
                        isFullScreen: $isFullScreen,
                        playbackSpeed: $currentPlaybackSpeed,
                        onShare: {
                            showShareSheet = true
                        }
                    )
                }
                
                // Loading indicator
                if playerController.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                }
                
                // iOS 18: HDR badge
                if playerController.hasHDRContent {
                    HDRBadge()
                        .position(x: geometry.size.width - 50, y: 30)
                }
            }
            .background(Color.black)
            .onAppear {
                if autoPlay {
                    playerController.play()
                }
                playerController.setupNotifications()
            }
            .onDisappear {
                playerController.cleanup()
            }
            .onChange(of: scenePhase) { _, newPhase in
                playerController.handleScenePhaseChange(newPhase)
            }
            .onChange(of: currentPlaybackSpeed) { _, newSpeed in
                playerController.setPlaybackSpeed(newSpeed)
            }
            .sheet(isPresented: $showShareSheet) {
                VideoShareSheet(videoURL: videoURL)
            }
        }
        #elseif os(macOS)
        // macOS implementation using VideoPlayer
        VideoPlayer(player: playerController.player)
            .onAppear {
                if autoPlay {
                    playerController.play()
                }
            }
            .onDisappear {
                playerController.pause()
            }
        #endif
    }
}

// MARK: - Enhanced Video Player Controller

@available(iOS 18.0, *)
@MainActor
class EnhancedVideoPlayerController: ObservableObject {
    @Published var player: AVPlayer
    @Published var isPlaying: Bool = false
    @Published var isLoading: Bool = true
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var bufferedTime: Double = 0
    @Published var hasHDRContent: Bool = false
    @Published var isUsingSystemControls: Bool = false
    @Published var videoBitrate: Double = 0
    @Published var droppedFrameCount: Int = 0
    
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "blue.catbird", category: "VideoPlayerController")
    
    // iOS 18: ProMotion support
    #if os(iOS)
    private var displayLink: CADisplayLink?
    #endif
    private let targetFrameRate: Float = 120.0 // ProMotion displays
    
    init(url: URL) {
        self.player = AVPlayer()
        setupPlayer(with: url)
        #if os(iOS)
        setupProMotionSupport()
        #endif
    }
    
    private func setupPlayer(with url: URL) {
        let asset = AVURLAsset(url: url)
        
        // iOS 18: Configure for optimal streaming
        asset.resourceLoader.preloadsEligibleContentKeys = true
        
        playerItem = AVPlayerItem(asset: asset)
        
        // iOS 18: Configure for HDR and high frame rate content
        if let playerItem = playerItem {
            // Enable extended dynamic range
            playerItem.preferredMaximumResolution = CGSize(width: 3840, height: 2160) // 4K
            playerItem.preferredPeakBitRate = 50_000_000 // 50 Mbps for high quality
            
            // iOS 18: Video composition for HDR
            checkForHDRContent(asset: asset)
            
            // Set up adaptive bitrate
            playerItem.preferredForwardBufferDuration = 5.0 // Buffer 5 seconds ahead
            
            player.replaceCurrentItem(with: playerItem)
            setupObservers()
        }
    }
    
    #if os(iOS)
    private func setupProMotionSupport() {
        // iOS 18: Create display link for ProMotion refresh rates
        displayLink = CADisplayLink(target: self, selector: #selector(displayLinkUpdate))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 120,
            preferred: 60
        )
        displayLink?.add(to: .main, forMode: .common)
    }
    
    @objc private func displayLinkUpdate() {
        // Update UI at display refresh rate for smooth playback
        if isPlaying {
            currentTime = player.currentTime().seconds
        }
    }
    #endif
    
    private func checkForHDRContent(asset: AVURLAsset) {
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let videoTrack = tracks.first {
                    let formatDescriptions = try await videoTrack.load(.formatDescriptions)
                    
                    for desc in formatDescriptions {
                        if let formatDesc = desc as? CMFormatDescription {
                            // Check for HDR metadata
                            if let extensions = CMFormatDescriptionGetExtensions(formatDesc) as? [String: Any] {
                                // iOS 18: Check for HDR10, HDR10+, or Dolby Vision
                                let hasHDR = extensions.keys.contains { key in
                                    key.contains("HDR") || key.contains("DolbyVision")
                                }
                                await MainActor.run {
                                    self.hasHDRContent = hasHDR
                                }
                                
                                if hasHDR {
                                    logger.info("🎬 HDR content detected")
                                }
                            }
                        }
                    }
                    
                    // Get video bitrate
                    let bitrate = try await videoTrack.load(.estimatedDataRate)
                    await MainActor.run {
                        self.videoBitrate = Double(bitrate)
                    }
                }
            } catch {
                logger.error("Failed to analyze video track: \(error)")
            }
        }
    }
    
    private func setupObservers() {
        // Player status observer
        player.publisher(for: \.status)
            .sink { [weak self] status in
                self?.handlePlayerStatusChange(status)
            }
            .store(in: &cancellables)
        
        // Time observer for playback progress
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            self?.currentTime = time.seconds
        }
        
        // Buffer observer
        playerItem?.publisher(for: \.loadedTimeRanges)
            .sink { [weak self] timeRanges in
                self?.updateBufferedTime(timeRanges)
            }
            .store(in: &cancellables)
        
        // Duration observer
        playerItem?.publisher(for: \.duration)
            .sink { [weak self] duration in
                if !duration.isIndefinite {
                    self?.duration = duration.seconds
                }
            }
            .store(in: &cancellables)
        
        // iOS 18: Playback metrics observer
        if let playerItem = playerItem {
            let accessLog = playerItem.accessLog()
            if let lastEvent = accessLog?.events.last {
                droppedFrameCount = lastEvent.numberOfDroppedVideoFrames
            }
        }
    }
    
    private func handlePlayerStatusChange(_ status: AVPlayer.Status) {
        switch status {
        case .readyToPlay:
            isLoading = false
            logger.info("Player ready to play")
        case .failed:
            isLoading = false
            if let error = player.error {
                logger.error("Player failed: \(error)")
            }
        case .unknown:
            break
        @unknown default:
            break
        }
    }
    
    private func updateBufferedTime(_ timeRanges: [NSValue]) {
        guard let timeRange = timeRanges.first?.timeRangeValue else { return }
        let bufferedTime = CMTimeGetSeconds(CMTimeAdd(timeRange.start, timeRange.duration))
        self.bufferedTime = bufferedTime
    }
    
    // MARK: - Playback Control
    
    func play() {
        player.play()
        isPlaying = true
        
        // iOS 18: Optimize for smooth playback
        player.automaticallyWaitsToMinimizeStalling = true
        player.rate = 1.0
    }
    
    func pause() {
        player.pause()
        isPlaying = false
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        
        // iOS 18: Smooth seeking with tolerance
        player.seek(
            to: cmTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] completed in
            if completed {
                self?.logger.debug("Seek completed to \(time)s")
            }
        }
    }
    
    func setPlaybackSpeed(_ speed: PlaybackSpeed) {
        player.rate = speed.rate
        
        // iOS 18: Adjust audio pitch for natural sound at different speeds
        if let playerItem = playerItem {
            playerItem.audioTimePitchAlgorithm = speed.pitchAlgorithm
        }
    }
    
    // MARK: - Scene Management
    
    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Continue audio playback in background if appropriate
            break
        case .inactive:
            // Pause if going to background
            #if os(iOS)
            if !AVAudioSession.sharedInstance().isOtherAudioPlaying {
                pause()
            }
            #else
            // macOS doesn't use AVAudioSession - pause on inactive for all cases
            pause()
            #endif
        case .active:
            // Resume if was playing
            break
        @unknown default:
            break
        }
    }
    
    func handlePlaybackStateChange(_ state: PlaybackState) {
        // Handle state changes from system controls
    }
    
    func setupNotifications() {
        // Set up remote control and now playing info
        setupNowPlayingInfo()
        setupRemoteCommands()
    }
    
    private func setupNowPlayingInfo() {
        // iOS 18: Enhanced now playing info
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = "Video Title"
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = player.rate
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func setupRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] (event: MPRemoteCommandEvent) in
            self?.play()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] (event: MPRemoteCommandEvent) in
            self?.pause()
            return .success
        }
        
        // iOS 18: Skip intervals for precise control
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] (event: MPRemoteCommandEvent) in
            guard let self = self else { return .commandFailed }
            self.seek(to: min(self.currentTime + 15, self.duration))
            return .success
        }
        
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] (event: MPRemoteCommandEvent) in
            guard let self = self else { return .commandFailed }
            self.seek(to: max(self.currentTime - 15, 0))
            return .success
        }
    }
    
    func cleanup() {
        #if os(iOS)
        displayLink?.invalidate()
        displayLink = nil
        #endif
        
        if let timeObserver = timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        
        player.pause()
        cancellables.removeAll()
    }
    
    deinit {
        Task { @MainActor in
            self.cleanup()
        }
    }
}

// MARK: - Supporting Types

enum PlaybackSpeed: CaseIterable {
    case slow
    case normal
    case fast
    case veryFast
    
    var rate: Float {
        switch self {
        case .slow: return 0.5
        case .normal: return 1.0
        case .fast: return 1.5
        case .veryFast: return 2.0
        }
    }
    
    var label: String {
        switch self {
        case .slow: return "0.5x"
        case .normal: return "1x"
        case .fast: return "1.5x"
        case .veryFast: return "2x"
        }
    }
    
    // iOS 18: Audio pitch algorithm for natural sound
    var pitchAlgorithm: AVAudioTimePitchAlgorithm {
        switch self {
        case .slow, .fast, .veryFast:
            return .timeDomain // Better for speech
        case .normal:
            return .spectral // Better for music
        }
    }
}

enum PlaybackState {
    case playing
    case paused
    case buffering
    case ended
    case failed(Error)
}

// MARK: - Video Player View Representable

#if os(iOS)
@available(iOS 18.0, *)
struct VideoPlayerViewRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    let showControls: Bool
    let enablePiP: Bool
    let onPlaybackStateChange: (PlaybackState) -> Void
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showControls
        
        // iOS 18: Configure for Picture in Picture
        if enablePiP {
            controller.allowsPictureInPicturePlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        
        // iOS 18: Enhanced video gravity
        controller.videoGravity = .resizeAspectFill
        
        // iOS 18: Speed controls
        controller.speeds = PlaybackSpeed.allCases.map { AVPlaybackSpeed(rate: $0.rate, localizedName: $0.label) }
        
        controller.delegate = context.coordinator
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Update if needed
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onPlaybackStateChange: onPlaybackStateChange)
    }
    
    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let onPlaybackStateChange: (PlaybackState) -> Void
        
        init(onPlaybackStateChange: @escaping (PlaybackState) -> Void) {
            self.onPlaybackStateChange = onPlaybackStateChange
        }
        
        // iOS 18: PiP delegate methods
        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            // Handle PiP start
        }
        
        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            // Handle PiP stop
        }
    }
}
#endif

// MARK: - Custom Controls Overlay

@available(iOS 18.0, *)
struct CustomVideoControlsOverlay: View {
    @ObservedObject var playerController: EnhancedVideoPlayerController
    @Binding var isFullScreen: Bool
    @Binding var playbackSpeed: PlaybackSpeed
    let onShare: () -> Void
    
    @State private var showControls: Bool = true
    @State private var controlsTimer: Timer?
    
    var body: some View {
        ZStack {
            // Tap to toggle controls
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showControls.toggle()
                    }
                    resetControlsTimer()
                }
            
            if showControls {
                VStack {
                    // Top bar
                    HStack {
                        // Quality indicator
                        if playerController.videoBitrate > 0 {
                            VideoBitrateIndicator(bitrate: playerController.videoBitrate)
                        }
                        
                        Spacer()
                        
                        // Share button
                        Button(action: onShare) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.white)
                        }
                        
                        // Fullscreen toggle
                        Button {
                            isFullScreen.toggle()
                        } label: {
                            Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .foregroundColor(.white)
                        }
                    }
                    .padding()
                    .background(LinearGradient(
                        colors: [.black.opacity(0.7), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    
                    Spacer()
                    
                    // Bottom controls
                    VStack(spacing: 12) {
                        // Progress bar
                        VideoProgressBar(
                            currentTime: playerController.currentTime,
                            duration: playerController.duration,
                            bufferedTime: playerController.bufferedTime,
                            onSeek: { time in
                                playerController.seek(to: time)
                            }
                        )
                        
                        // Playback controls
                        HStack(spacing: 30) {
                            // Skip backward
                            Button {
                                playerController.seek(to: max(playerController.currentTime - 15, 0))
                            } label: {
                                Image(systemName: "gobackward.15")
                                    .font(.title2)
                                    .foregroundColor(.white)
                            }
                            
                            // Play/Pause
                            Button {
                                playerController.togglePlayPause()
                            } label: {
                                Image(systemName: playerController.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.largeTitle)
                                    .foregroundColor(.white)
                            }
                            
                            // Skip forward
                            Button {
                                playerController.seek(to: min(playerController.currentTime + 15, playerController.duration))
                            } label: {
                                Image(systemName: "goforward.15")
                                    .font(.title2)
                                    .foregroundColor(.white)
                            }
                            
                            Spacer()
                            
                            // Speed control
                            Menu {
                                ForEach(PlaybackSpeed.allCases, id: \.self) { speed in
                                    Button {
                                        playbackSpeed = speed
                                    } label: {
                                        Label(speed.label, systemImage: playbackSpeed == speed ? "checkmark" : "")
                                    }
                                }
                            } label: {
                                Text(playbackSpeed.label)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding()
                    .background(LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            resetControlsTimer()
        }
    }
    
    private func resetControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            if playerController.isPlaying {
                withAnimation {
                    showControls = false
                }
            }
        }
    }
}

// MARK: - Helper Views

struct HDRBadge: View {
    var body: some View {
        Text("HDR")
            .font(.caption.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                LinearGradient(
                    colors: [.orange, .pink],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
    }
}

struct VideoBitrateIndicator: View {
    let bitrate: Double
    
    var qualityLabel: String {
        if bitrate > 10_000_000 {
            return "4K"
        } else if bitrate > 5_000_000 {
            return "1080p"
        } else if bitrate > 2_500_000 {
            return "720p"
        } else {
            return "SD"
        }
    }
    
    var body: some View {
        Text(qualityLabel)
            .font(.caption.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.2))
            .clipShape(Capsule())
    }
}

struct VideoProgressBar: View {
    let currentTime: Double
    let duration: Double
    let bufferedTime: Double
    let onSeek: (Double) -> Void
    
    @State private var isDragging: Bool = false
    @State private var dragTime: Double = 0
    
    var displayTime: Double {
        isDragging ? dragTime : currentTime
    }
    
    var progress: Double {
        guard duration > 0 else { return 0 }
        return displayTime / duration
    }
    
    var bufferedProgress: Double {
        guard duration > 0 else { return 0 }
        return bufferedTime / duration
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 4)
                
                // Buffered progress
                Rectangle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: geometry.size.width * bufferedProgress, height: 4)
                
                // Current progress
                Rectangle()
                    .fill(Color.white)
                    .frame(width: geometry.size.width * progress, height: 4)
                
                // Scrubber
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .position(x: geometry.size.width * progress, y: 2)
            }
            .frame(height: 4)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let progress = max(0, min(1, value.location.x / geometry.size.width))
                        dragTime = progress * duration
                    }
                    .onEnded { _ in
                        onSeek(dragTime)
                        isDragging = false
                    }
            )
        }
        .frame(height: 20)
    }
}

#if os(iOS)
struct VideoShareSheet: UIViewControllerRepresentable {
    let videoURL: URL
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [videoURL], applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#elseif os(macOS)
struct VideoShareSheet: NSViewControllerRepresentable {
    let videoURL: URL
    
    func makeNSViewController(context: Context) -> NSSharingServicePickerViewController {
        let picker = NSSharingServicePicker(items: [videoURL])
        let viewController = NSViewController()
        
        // Show sharing service picker
        picker.show(relativeTo: .zero, of: viewController.view, preferredEdge: .minY)
        
        return NSSharingServicePickerViewController()
    }
    
    func updateNSViewController(_ nsViewController: NSSharingServicePickerViewController, context: Context) {}
}

// Simple wrapper for NSSharingServicePicker on macOS
class NSSharingServicePickerViewController: NSViewController {
    override func loadView() {
        self.view = NSView()
    }
}
#endif

// MARK: - Preview

@available(iOS 18.0, *)
struct iOS18EnhancedVideoPlayer_Previews: PreviewProvider {
    static var previews: some View {
        iOS18EnhancedVideoPlayer(
            videoURL: URL(string: "https://example.com/video.mp4")!,
            autoPlay: true,
            showControls: true,
            enablePiP: true
        )
    }
}