//
//  PlayerLayerView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/24/24.
//

import AVKit
/// A SwiftUI wrapper around AVPlayerLayer that efficiently renders videos with minimal main thread impact
import SwiftUI
import os.log

/// A SwiftUI wrapper around AVPlayerLayer that efficiently renders videos with minimal main thread impact
struct PlayerLayerView: UIViewRepresentable {

  let player: AVPlayer
  let gravity: AVLayerVideoGravity
  let size: CGSize
  let shouldLoop: Bool
  var onLayerReady: ((AVPlayerLayer) -> Void)?

  /// Initialize the player view
  /// - Parameters:
  ///   - player: The AVPlayer to use
  ///   - gravity: Video gravity (defaults to resizeAspectFill)
  ///   - size: The desired size
  ///   - shouldLoop: Whether the video should loop (defaults to true)
  ///   - onLayerReady: Optional callback when the player layer is ready
  init(
    player: AVPlayer,
    gravity: AVLayerVideoGravity = .resizeAspectFill,
    size: CGSize,
    shouldLoop: Bool = true,
    onLayerReady: ((AVPlayerLayer) -> Void)? = nil
  ) {
    self.player = player
    self.gravity = gravity
    self.size = size
    self.shouldLoop = shouldLoop
    self.onLayerReady = onLayerReady
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

    // Notify when layer is ready for PiP setup
    onLayerReady?(view.playerLayer)

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
    private let logger = Logger(subsystem: "blue.catbird", category: "PlayerLayerView")

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
final class PlayerContainer: UIView {
  // Reference to coordinator for async operations
  weak var coordinator: PlayerLayerView.Coordinator?

  private var loopObserver: NSObjectProtocol?
  private var statusObserver: NSObjectProtocol?
  private var isCleanedUp = false

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
      // Prevent multiple assignments and cleanup cycles
      guard newValue !== playerLayer.player && !isCleanedUp else { return }

      // Remove any existing observers when changing players
      removeAllObservers()

      playerLayer.player = newValue

      // Set up new observers if needed
      setupObservers()
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
    // Only update frame if not cleaned up
    guard !isCleanedUp else { return }
    playerLayer.frame = bounds
  }

  // MARK: - Observer Management

  private func setupObservers() {
    guard !isCleanedUp else { return }
    setupLoopObserver()
    setupStatusObserver()
  }

  private func removeAllObservers() {
    removeLoopObserver()
    removeStatusObserver()
  }

  // Enhanced loop observer setup - KEEP THIS FOR VIDEO LOOPING
  private func setupLoopObserver() {
    guard shouldLoop, let currentItem = player?.currentItem, loopObserver == nil else { return }

    loopObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: currentItem,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, !self.isCleanedUp else { return }
      // This is essential for GIFs and looping videos
      self.player?.seek(to: .zero)
      self.player?.safePlay()
    }
  }

  // Add status observer for better error handling
  private func setupStatusObserver() {
    guard let currentItem = player?.currentItem, statusObserver == nil else { return }

    statusObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: currentItem,
      queue: .main
    ) { [weak self] notification in
      guard let self = self, !self.isCleanedUp else { return }
      if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
        // Log error but don't crash
        print("Player failed to play to end: \(error)")
      }
    }
  }

  // Remove loop observer
  private func removeLoopObserver() {
    if let observer = loopObserver {
      NotificationCenter.default.removeObserver(observer)
      loopObserver = nil
    }
  }

  // Remove status observer
  private func removeStatusObserver() {
    if let observer = statusObserver {
      NotificationCenter.default.removeObserver(observer)
      statusObserver = nil
    }
  }

  // Enhanced cleanup with safety checks
  func cleanup() {
    guard !isCleanedUp else { return }
    isCleanedUp = true

    // Pause player first
    player?.pause()

    // Remove all observers
    removeAllObservers()

    // Clear player reference
    playerLayer.player = nil

    // Clear coordinator reference
    coordinator = nil
  }

  deinit {
    cleanup()
  }
}
