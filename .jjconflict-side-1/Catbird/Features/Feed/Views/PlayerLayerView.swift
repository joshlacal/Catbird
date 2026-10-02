//
//  PlayerLayerView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 10/24/24.
//

import AVKit
import SwiftUI
import os.log
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A SwiftUI wrapper around AVPlayerLayer that efficiently renders videos with minimal main thread impact
#if os(iOS)
struct PlayerLayerView: UIViewRepresentable {

  let player: AVPlayer
  let gravity: AVLayerVideoGravity
  let shouldLoop: Bool
  let pausesOnDismantle: Bool
  var onLayerReady: ((AVPlayerLayer) -> Void)?

  /// Initialize the player view
  /// - Parameters:
  ///   - player: The AVPlayer to use
  ///   - gravity: Video gravity (defaults to resizeAspectFill)
  ///   - shouldLoop: Whether the video should loop (defaults to true)
  ///   - onLayerReady: Optional callback when the player layer is ready
  init(
    player: AVPlayer,
    gravity: AVLayerVideoGravity = .resizeAspectFill,
    shouldLoop: Bool = true,
    pausesOnDismantle: Bool = true,
    onLayerReady: ((AVPlayerLayer) -> Void)? = nil
  ) {
    self.player = player
    self.gravity = gravity
    self.shouldLoop = shouldLoop
    self.pausesOnDismantle = pausesOnDismantle
    self.onLayerReady = onLayerReady
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeUIView(context: Context) -> PlayerContainer {
    let view = PlayerContainer(frame: .zero)
    view.backgroundColor = .black
    view.playerLayer.videoGravity = gravity
    // Hint to the compositor: no blending needed for video layer
    view.playerLayer.isOpaque = true
    view.coordinator = context.coordinator

    // Layer attachment is synchronous; the owner controls asynchronous asset loading.
    context.coordinator.configurePlayer(for: view, player: player, shouldLoop: shouldLoop)

    return view
  }

  func updateUIView(_ uiView: PlayerContainer, context: Context) {
    context.coordinator.parent = self
    uiView.pausesOnDismantle = pausesOnDismantle
    if uiView.player !== player {
      context.coordinator.configurePlayer(for: uiView, player: player, shouldLoop: shouldLoop)
    }

    // Update other properties
    uiView.playerLayer.videoGravity = gravity
    uiView.shouldLoop = shouldLoop
  }

  static func dismantleUIView(_ uiView: PlayerContainer, coordinator: Coordinator) {
    // Release resources
    uiView.cleanup()
  }

  @MainActor
  class Coordinator {
    var parent: PlayerLayerView

    init(_ parent: PlayerLayerView) {
      self.parent = parent
    }

    func configurePlayer(for view: PlayerContainer, player: AVPlayer, shouldLoop: Bool) {
      player.currentItem?.preferredForwardBufferDuration = 2
      player.actionAtItemEnd = .none
      view.pausesOnDismantle = parent.pausesOnDismantle
      view.shouldLoop = shouldLoop
      view.player = player
      parent.onLayerReady?(view.playerLayer)
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

  /// A pool-owned player must keep playing when an old page releases its layer.
  var pausesOnDismantle = true

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
      // Seamless loop: seek with infinite tolerance for performance
      self.player?.seek(to: .zero, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
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
        logger.debug("Player failed to play to end: \(error)")
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

    if pausesOnDismantle { player?.pause() }

    // Remove all observers
    removeAllObservers()

    // Clear player reference
    playerLayer.player = nil

    // Clear coordinator reference
    coordinator = nil
  }

  isolated deinit {
    cleanup()
  }
}
#elseif os(macOS)
/// macOS implementation using NSView and AVPlayerLayer
struct PlayerLayerView: NSViewRepresentable {
  let player: AVPlayer
  let gravity: AVLayerVideoGravity
  let shouldLoop: Bool
  let pausesOnDismantle: Bool
  var onLayerReady: ((AVPlayerLayer) -> Void)?

  init(
    player: AVPlayer,
    gravity: AVLayerVideoGravity = .resizeAspectFill,
    shouldLoop: Bool = true,
    pausesOnDismantle: Bool = true,
    onLayerReady: ((AVPlayerLayer) -> Void)? = nil
  ) {
    self.player = player
    self.gravity = gravity
    self.shouldLoop = shouldLoop
    self.pausesOnDismantle = pausesOnDismantle
    self.onLayerReady = onLayerReady
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  func makeNSView(context: Context) -> PlayerContainerMac {
    let view = PlayerContainerMac(frame: .zero)
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.black.cgColor
    view.playerLayer.videoGravity = gravity
    view.playerLayer.isOpaque = true
    view.coordinator = context.coordinator

    // Layer attachment is synchronous; the owner controls asynchronous asset loading.
    context.coordinator.configurePlayer(for: view, player: player, shouldLoop: shouldLoop)

    return view
  }

  func updateNSView(_ nsView: PlayerContainerMac, context: Context) {
    context.coordinator.parent = self
    nsView.pausesOnDismantle = pausesOnDismantle
    if nsView.player !== player {
      context.coordinator.configurePlayer(for: nsView, player: player, shouldLoop: shouldLoop)
    }

    // Update other properties
    nsView.playerLayer.videoGravity = gravity
    nsView.shouldLoop = shouldLoop
  }

  static func dismantleNSView(_ nsView: PlayerContainerMac, coordinator: Coordinator) {
    nsView.cleanup()
  }

  @MainActor
  class Coordinator {
    var parent: PlayerLayerView

    init(_ parent: PlayerLayerView) {
      self.parent = parent
    }

    func configurePlayer(for view: PlayerContainerMac, player: AVPlayer, shouldLoop: Bool) {
      player.currentItem?.preferredForwardBufferDuration = 2
      player.actionAtItemEnd = .none
      view.pausesOnDismantle = parent.pausesOnDismantle
      view.shouldLoop = shouldLoop
      view.player = player
      parent.onLayerReady?(view.playerLayer)
    }
  }
}

/// NSView subclass that hosts the AVPlayerLayer and manages playback on macOS
final class PlayerContainerMac: NSView {
  weak var coordinator: PlayerLayerView.Coordinator?

  private var loopObserver: NSObjectProtocol?
  private var statusObserver: NSObjectProtocol?
  private var isCleanedUp = false

  /// A pool-owned player must keep playing when an old page releases its layer.
  var pausesOnDismantle = true

  var shouldLoop: Bool = true {
    didSet {
      if oldValue != shouldLoop {
        removeLoopObserver()
        setupLoopObserver()
      }
    }
  }

  var player: AVPlayer? {
    get { playerLayer.player }
    set {
      guard newValue !== playerLayer.player && !isCleanedUp else { return }
      removeAllObservers()
      playerLayer.player = newValue
      setupObservers()
    }
  }

  var playerLayer: AVPlayerLayer {
    guard let layer = layer as? AVPlayerLayer else {
      fatalError("Layer expected to be of type AVPlayerLayer")
    }
    return layer
  }

  override func makeBackingLayer() -> CALayer {
    return AVPlayerLayer()
  }

  override func layout() {
    super.layout()
    guard !isCleanedUp else { return }
    playerLayer.frame = bounds
  }

  private func setupObservers() {
    guard !isCleanedUp else { return }
    setupLoopObserver()
    setupStatusObserver()
  }

  private func removeAllObservers() {
    removeLoopObserver()
    removeStatusObserver()
  }

  private func setupLoopObserver() {
    guard shouldLoop, let currentItem = player?.currentItem, loopObserver == nil else { return }

    loopObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: currentItem,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, !self.isCleanedUp else { return }
      self.player?.seek(to: .zero, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
      self.player?.safePlay()
    }
  }

  private func setupStatusObserver() {
    guard let currentItem = player?.currentItem, statusObserver == nil else { return }

    statusObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: currentItem,
      queue: .main
    ) { [weak self] notification in
      guard let self = self, !self.isCleanedUp else { return }
      if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
        logger.debug("Player failed to play to end: \(error)")
      }
    }
  }

  private func removeLoopObserver() {
    if let observer = loopObserver {
      NotificationCenter.default.removeObserver(observer)
      loopObserver = nil
    }
  }

  private func removeStatusObserver() {
    if let observer = statusObserver {
      NotificationCenter.default.removeObserver(observer)
      statusObserver = nil
    }
  }

  func cleanup() {
    guard !isCleanedUp else { return }
    isCleanedUp = true

    if pausesOnDismantle { player?.pause() }
    removeAllObservers()
    playerLayer.player = nil
    coordinator = nil
  }

  isolated deinit {
    cleanup()
  }
}
#endif
