//
//  PlayerLayerView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/24/24.
//

/// A SwiftUI wrapper around AVPlayerLayer that efficiently renders videos with minimal main thread impact
import SwiftUI
import AVKit

/// A SwiftUI wrapper around AVPlayerLayer that efficiently renders videos with minimal main thread impact
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let size: CGSize
    let shouldLoop: Bool
    
    /// Initialize the player view
    /// - Parameters:
    ///   - player: The AVPlayer to use
    ///   - gravity: Video gravity (defaults to resizeAspectFill)
    ///   - size: The desired size
    ///   - shouldLoop: Whether the video should loop (defaults to true)
    init(
        player: AVPlayer,
        gravity: AVLayerVideoGravity = .resizeAspectFill,
        size: CGSize,
        shouldLoop: Bool = true
    ) {
        self.player = player
        self.gravity = gravity
        self.size = size
        self.shouldLoop = shouldLoop
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> PlayerContainer {
        let view = PlayerContainer(frame: CGRect(origin: .zero, size: size))
        view.backgroundColor = .black
        view.playerLayer.videoGravity = gravity
        view.coordinator = context.coordinator
        
        // Set player and loop configuration asynchronously to prevent main thread blocking
        context.coordinator.configurePlayerAsync(for: view, player: player, shouldLoop: shouldLoop)
        
        return view
    }
    
    func updateUIView(_ uiView: PlayerContainer, context: Context) {
        // Update player if needed without blocking
        if uiView.player !== player {
            context.coordinator.configurePlayerAsync(for: uiView, player: player, shouldLoop: shouldLoop)
        }
        
        // Update other properties
        uiView.playerLayer.videoGravity = gravity
        uiView.frame = CGRect(origin: .zero, size: size)
        uiView.shouldLoop = shouldLoop
    }
    
    static func dismantleUIView(_ uiView: PlayerContainer, coordinator: Coordinator) {
        // Release resources
        uiView.cleanup()
    }
    
    // Coordinator class to handle async operations
    class Coordinator {
        private let parent: PlayerLayerView
        
        init(_ parent: PlayerLayerView) {
            self.parent = parent
        }
        
        // Configure player asynchronously to avoid main thread blocking
        func configurePlayerAsync(for view: PlayerContainer, player: AVPlayer, shouldLoop: Bool) {
            Task {
                // Ensure we don't block the main thread with property access
                await preparePlayer(player)
                
                // Update the view on the main thread
                await MainActor.run {
                    view.player = player
                    view.shouldLoop = shouldLoop
                }
            }
        }
        
        // Pre-load key asset properties to avoid synchronous access later
        private func preparePlayer(_ player: AVPlayer) async {
            guard let asset = await player.currentItem?.asset as? AVURLAsset else { return }
            
            // Pre-load potentially blocking properties asynchronously
            do {
                // Load essential properties in parallel for efficiency
                async let duration = asset.load(.duration)
                async let transform = asset.load(.preferredTransform)
                async let tracks = asset.load(.tracks)
                
                // Wait for all to complete
                _ = try await (duration, transform, tracks)
                
                // Set reasonable buffer duration
                player.currentItem?.preferredForwardBufferDuration = 5.0
            } catch {
                logger.debug("Error pre-loading asset properties: \(error)")
            }
        }
    }
}

/// UIView subclass that hosts the AVPlayerLayer and manages playback
// Simplified PlayerContainer without custom looping logic
final class PlayerContainer: UIView {
    // Reference to coordinator for async operations
    weak var coordinator: PlayerLayerView.Coordinator?
    
    private var loopObserver: NSObjectProtocol?

    /// Whether this player should loop automatically
    var shouldLoop: Bool = true {
        didSet {
            if oldValue != shouldLoop {
                // Update loop observer when shouldLoop changes
                removeLoopObserver()
                setupLoopObserver()
            }
        }
    }

    /// The player driving this view
    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            // Remove any existing loop observer when changing players
            removeLoopObserver()
            
            playerLayer.player = newValue
            
            // Set up new loop observer if needed
            setupLoopObserver()
        }
    }
    
    /// Access the player layer (AVPlayerLayer is the layer class for this view)
    var playerLayer: AVPlayerLayer {
        guard let layer = layer as? AVPlayerLayer else {
            fatalError("Layer expected to be of type AVPlayerLayer")
        }
        return layer
    }
    
    // MARK: - UIView Lifecycle
    
    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
    
    // Add method to set up loop observer
    private func setupLoopObserver() {
        guard shouldLoop, let currentItem = player?.currentItem else { return }
        
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { [weak player = self.player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }
    
    // Add method to remove loop observer
    private func removeLoopObserver() {
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
    }
    
    // Update cleanup to handle the observer
    func cleanup() {
        player?.pause()
        removeLoopObserver()
        playerLayer.player = nil
    }
    
    deinit {
        cleanup()
    }
}
