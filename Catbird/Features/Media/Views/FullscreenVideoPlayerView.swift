//
//  FullscreenVideoPlayerView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/26/25.
//

// Simplified version that uses the built-in Done button
import SwiftUI
import AVKit
import AVFoundation
import Petrel
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import AVFoundation
#endif

struct FullscreenVideoPlayerView: View {
    let originalPlayer: AVPlayer
    let model: VideoModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        
        #if os(macOS)
        AVPlayerViewControllerWrapper(player: originalPlayer, onDismiss: {
            dismiss()
        })
        .platformIgnoresSafeArea()
        .onAppear {
            // Respect prior mute state to avoid interrupting external audio
            if !model.isMuted {
                AudioSessionManager.shared.handleVideoUnmute()
                originalPlayer.isMuted = false
                originalPlayer.volume = 1.0
            } else {
                // Keep muted and do not escalate audio session
                originalPlayer.isMuted = true
                originalPlayer.volume = 0
            }
        }
        .onDisappear {
            // Restore muted state for feed if needed
            if model.isMuted {
                originalPlayer.isMuted = true
                originalPlayer.volume = 0
            }
        }
        // Enable swipe to dismiss
        #elseif os(iOS)
        AVPlayerViewControllerWrapper(player: originalPlayer, model: model, onDismiss: {
            dismiss()
        })
        .platformIgnoresSafeArea()
        .statusBar(hidden: true)
        .onAppear {
            // Respect prior mute state to avoid interrupting external audio
            if !model.isMuted {
                AudioSessionManager.shared.handleVideoUnmute()
                originalPlayer.isMuted = false
                originalPlayer.volume = 1.0
            } else {
                // Keep muted and do not escalate audio session
                originalPlayer.isMuted = true
                originalPlayer.volume = 0
            }
        }
        .onDisappear {
            // Restore muted state for feed if needed
            if model.isMuted {
                originalPlayer.isMuted = true
                originalPlayer.volume = 0
            }
        }
        .interactiveDismissDisabled(false)
        #endif
    }
}

#if os(iOS)
struct AVPlayerViewControllerWrapper: UIViewControllerRepresentable {
    let player: AVPlayer
    let model: VideoModel
    let onDismiss: () -> Void
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        
        // Configure for fullscreen experience
        controller.showsPlaybackControls = true
        controller.entersFullScreenWhenPlaybackBegins = true
        controller.updatesNowPlayingInfoCenter = true
        
        // Start observing system-driven volume/mute changes
        context.coordinator.startObserving(player: player)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Nothing to update
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let parent: AVPlayerViewControllerWrapper
        private var isAdjustingProgrammatically = false
        private var isMutedObservation: NSKeyValueObservation?
        private var outputVolumeObservation: NSKeyValueObservation?
        
        init(_ parent: AVPlayerViewControllerWrapper) {
            self.parent = parent
        }
        
        deinit {
            stopObserving()
        }

        func startObserving(player: AVPlayer) {
            // Observe player.isMuted changes (e.g., if system UI toggles it)
            isMutedObservation = player.observe(\.isMuted, options: [.new]
            ) { [weak self] player, change in
                guard let self = self, let newValue = change.newValue else { return }
                // Bridge to MainActor; KVO can arrive on a non-main queue
                Task { @MainActor in
                    self.handleMuteStateChange(player: player, isMuted: newValue)
                }
            }

            // Observe system output volume; if user raises volume while we muted, treat as intent to unmute
            let session = AVAudioSession.sharedInstance()
            outputVolumeObservation = session.observe(\.outputVolume, options: [.new]
            ) { [weak self] _, change in
                guard let self = self, let vol = change.newValue else { return }
                // Only react when user increases volume to audible level and we are muted
                Task { @MainActor in
                    if vol > 0.01 && (self.parent.model.isMuted || self.parent.player.isMuted) {
                        self.userRequestedUnmute()
                    }
                }
            }
        }

        func stopObserving() {
            isMutedObservation?.invalidate()
            isMutedObservation = nil
            outputVolumeObservation?.invalidate()
            outputVolumeObservation = nil
        }

        @MainActor private func handleMuteStateChange(player: AVPlayer, isMuted: Bool) {
            // Avoid recursion if we are the ones changing it
            if isAdjustingProgrammatically { return }

            if isMuted == false {
                userRequestedUnmute()
            } else {
                // User muted via system UI; reflect in coordinator model
                VideoCoordinator.shared.setUnmuted(parent.model.id, unmuted: false)
            }
        }

        @MainActor private func userRequestedUnmute() {
            guard !isAdjustingProgrammatically else { return }
            isAdjustingProgrammatically = true
            defer { isAdjustingProgrammatically = false }
            // Route through VideoCoordinator so audio session and model state are handled uniformly
            VideoCoordinator.shared.setUnmuted(parent.model.id, unmuted: true)
        }

        // This is called when the user taps the built-in "Done" button
        func playerViewControllerDidEndFullScreenPresentation(_ playerViewController: AVPlayerViewController) {
            stopObserving()
            parent.onDismiss()
        }
    }
}
#elseif os(macOS)
struct AVPlayerViewControllerWrapper: NSViewRepresentable {
    let player: AVPlayer
    let onDismiss: () -> Void
    
    func makeNSView(context: Context) -> MacOSVideoPlayerView {
        let playerView = MacOSVideoPlayerView()
        playerView.setupPlayer(player, onDismiss: onDismiss)
        return playerView
    }
    
    func updateNSView(_ nsView: MacOSVideoPlayerView, context: Context) {
        // Nothing to update
    }
}

final class MacOSVideoPlayerView: NSView {
    private var playerLayer: AVPlayerLayer!
    private var player: AVPlayer?
    private var onDismiss: (() -> Void)?
    private var controlsContainer: NSView!
    private var playPauseButton: NSButton!
    private var progressSlider: NSSlider!
    private var timeLabel: NSTextField!
    private var fullscreenButton: NSButton!
    private var closeButton: NSButton!
    private var controlsVisible = true
    private var hideControlsTimer: Timer?
    private var timeObserver: Any?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        
        // Create player layer
        playerLayer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        
        setupControls()
        setupTrackingArea()
    }
    
    private func setupControls() {
        controlsContainer = NSView()
        controlsContainer.wantsLayer = true
        controlsContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        controlsContainer.layer?.cornerRadius = 8
        addSubview(controlsContainer)
        
        // Close button
        closeButton = NSButton()
        closeButton.title = "✕"
        closeButton.bezelStyle = .circular
        closeButton.target = self
        closeButton.action = #selector(closeButtonTapped)
        addSubview(closeButton)
        
        // Play/Pause button
        playPauseButton = NSButton()
        playPauseButton.title = "▶"
        playPauseButton.bezelStyle = .circular
        playPauseButton.target = self
        playPauseButton.action = #selector(playPauseButtonTapped)
        controlsContainer.addSubview(playPauseButton)
        
        // Progress slider
        progressSlider = NSSlider()
        progressSlider.minValue = 0
        progressSlider.maxValue = 1
        progressSlider.target = self
        progressSlider.action = #selector(progressSliderChanged)
        controlsContainer.addSubview(progressSlider)
        
        // Time label
        timeLabel = NSTextField()
        timeLabel.stringValue = "00:00 / 00:00"
        timeLabel.isEditable = false
        timeLabel.isBezeled = false
        timeLabel.backgroundColor = NSColor.clear
        timeLabel.textColor = NSColor.white
        controlsContainer.addSubview(timeLabel)
        
        // Fullscreen button
        fullscreenButton = NSButton()
        fullscreenButton.title = "⛶"
        fullscreenButton.bezelStyle = .circular
        fullscreenButton.target = self
        fullscreenButton.action = #selector(fullscreenButtonTapped)
        controlsContainer.addSubview(fullscreenButton)
    }
    
    private func setupTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    override func layout() {
        super.layout()
        
        playerLayer.frame = bounds
        
        // Layout controls
        let controlsHeight: CGFloat = 60
        let controlsY = bounds.height - controlsHeight - 20
        controlsContainer.frame = NSRect(x: 20, y: controlsY, width: bounds.width - 40, height: controlsHeight)
        
        // Close button (top-right)
        closeButton.frame = NSRect(x: bounds.width - 50, y: bounds.height - 50, width: 30, height: 30)
        
        // Controls layout within container
        let buttonSize: CGFloat = 30
        let padding: CGFloat = 10
        
        playPauseButton.frame = NSRect(x: padding, y: 15, width: buttonSize, height: buttonSize)
        
        fullscreenButton.frame = NSRect(
            x: controlsContainer.bounds.width - buttonSize - padding,
            y: 15,
            width: buttonSize,
            height: buttonSize
        )
        
        timeLabel.frame = NSRect(
            x: fullscreenButton.frame.minX - 120 - padding,
            y: 20,
            width: 120,
            height: 20
        )
        
        progressSlider.frame = NSRect(
            x: playPauseButton.frame.maxX + padding,
            y: 20,
            width: timeLabel.frame.minX - playPauseButton.frame.maxX - 2 * padding,
            height: 20
        )
    }
    
    func setupPlayer(_ player: AVPlayer, onDismiss: @escaping () -> Void) {
        self.player = player
        self.onDismiss = onDismiss
        playerLayer.player = player
        
        // Add time observer
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updateProgress()
        }
        
        // Update play/pause button based on player state
        updatePlayPauseButton()
        
        // Auto-hide controls after 3 seconds
        resetControlsTimer()
    }
    
    @objc private func closeButtonTapped() {
        onDismiss?()
    }
    
    @objc private func playPauseButtonTapped() {
        guard let player = player else { return }
        
        if player.rate > 0 {
            player.pause()
        } else {
            player.play()
        }
        updatePlayPauseButton()
        resetControlsTimer()
    }
    
    @objc private func progressSliderChanged() {
        guard let player = player,
              let duration = player.currentItem?.duration,
              duration.isValid && !duration.isIndefinite else { return }
        
        let targetTime = CMTime(seconds: progressSlider.doubleValue * duration.seconds, preferredTimescale: duration.timescale)
        player.seek(to: targetTime)
        resetControlsTimer()
    }
    
    @objc private func fullscreenButtonTapped() {
        // Toggle fullscreen using NSWindow
        if let window = window {
            window.toggleFullScreen(nil)
        }
        resetControlsTimer()
    }
    
    private func updatePlayPauseButton() {
        guard let player = player else { return }
        playPauseButton.title = player.rate > 0 ? "⏸" : "▶"
    }
    
    private func updateProgress() {
        guard let player = player,
              let currentItem = player.currentItem,
              currentItem.duration.isValid && !currentItem.duration.isIndefinite else {
            timeLabel.stringValue = "00:00 / 00:00"
            progressSlider.doubleValue = 0
            return
        }
        
        let currentTime = player.currentTime()
        let duration = currentItem.duration
        
        let currentSeconds = currentTime.seconds
        let durationSeconds = duration.seconds
        
        progressSlider.doubleValue = currentSeconds / durationSeconds
        
        let currentTimeString = formatTime(currentSeconds)
        let durationString = formatTime(durationSeconds)
        timeLabel.stringValue = "\(currentTimeString) / \(durationString)"
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
    
    override func mouseEntered(with event: NSEvent) {
        showControls()
    }
    
    override func mouseMoved(with event: NSEvent) {
        showControls()
        resetControlsTimer()
    }
    
    override func mouseExited(with event: NSEvent) {
        hideControlsAfterDelay()
    }
    
    private func showControls() {
        guard !controlsVisible else { return }
        
        controlsVisible = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            controlsContainer.animator().alphaValue = 1.0
            closeButton.animator().alphaValue = 1.0
        }
    }
    
    private func hideControls() {
        guard controlsVisible else { return }
        
        controlsVisible = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            controlsContainer.animator().alphaValue = 0.0
            closeButton.animator().alphaValue = 0.0
        }
    }
    
    private func hideControlsAfterDelay() {
        resetControlsTimer()
    }
    
    private func resetControlsTimer() {
        hideControlsTimer?.invalidate()
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.hideControls()
        }
    }
    
    deinit {
        hideControlsTimer?.invalidate()
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
    }
}
#endif
