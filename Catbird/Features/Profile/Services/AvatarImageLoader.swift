//
//  AvatarImageLoader.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/30/25.
//

import OSLog
import Petrel
import SwiftUI

#if os(iOS)
  import UIKit
  import Nuke
#elseif os(macOS)
  import AppKit
#endif

// MARK: - Cross-Platform Image Extensions

extension PlatformImage {
  // Prefer the centralized implementation in CrossPlatformImage.swift.
  // Keep this as a thin adapter to the shared API name to avoid duplication.
  func circularCropped(to size: CGSize) -> PlatformImage? {
    return self.circularCroppedImage(to: size)
  }
}

private actor AvatarTaskStore {
  private var tasks: [String: Task<PlatformImage?, Error>] = [:]

  func task(for key: String) -> Task<PlatformImage?, Error>? {
    tasks[key]
  }

  func set(_ task: Task<PlatformImage?, Error>, for key: String) {
    tasks[key] = task
  }

  func remove(for key: String) {
    tasks.removeValue(forKey: key)
  }

  func removeAll() {
    tasks.values.forEach { $0.cancel() }
    tasks.removeAll()
  }
}

final class AvatarImageLoader {
  static let shared = AvatarImageLoader()

  private let cache = NSCache<NSString, PlatformImage>()
  private let taskStore = AvatarTaskStore()
  private let maxRetryAttempts = 3
  private let baseBackoffNanoseconds: UInt64 = 200_000_000 // 0.2s
  private let logger = Logger(subsystem: "blue.catbird", category: "AvatarImageLoader")

  func clearCache() {
    cache.removeAllObjects()
    Task {
      await taskStore.removeAll()
    }
  }

  private func cacheKey(for did: String?, avatarURL: URL?, size: CGFloat) -> NSString {
    let identifier = avatarURL?.absoluteString ?? did ?? "unknown"
    return NSString(string: "avatar-\(identifier)-\(size)")
  }

  private func backoffDelay(for attempt: Int) -> UInt64 {
    let base = Double(baseBackoffNanoseconds) * pow(2.0, Double(attempt))
    let jitter = Double.random(in: 0...(base * 0.25))
    return UInt64(base + jitter)
  }

  private func fetchImage(from url: URL, size: CGFloat) async throws -> PlatformImage? {
    #if os(iOS)
      let request = ImageRequest(url: url)
      let response = try await ImagePipeline.shared.image(for: request)
      let image = response
      let targetSize = CGSize(width: size, height: size)
      if let rounded = image.circularCroppedImage(to: targetSize) {
        return rounded
      }
      return image
    #else
      let (data, _) = try await URLSession.shared.data(from: url)
      if let image = PlatformImage(data: data) {
        let sizeToUse = CGSize(width: size, height: size)
        if let resizedImage = image.circularCroppedImage(to: sizeToUse) {
          return resizedImage
        }
        return image
      }
      return nil
    #endif
  }

  private func resolveProfileAvatarURL(for did: String, client: ATProtoClient) async throws -> URL? {
    let profile = try await client.app.bsky.actor.getProfile(
      input: .init(actor: try ATIdentifier(string: did))
    ).data
    return profile?.finalAvatarURL()
  }

  func loadAvatar(
    did: String?,
    client: ATProtoClient?,
    avatarURL: URL?,
    size: CGFloat = 24
  ) async -> PlatformImage? {
    guard did != nil || avatarURL != nil else {
      return nil
    }

    let cacheKey = cacheKey(for: did, avatarURL: avatarURL, size: size)
    let cacheKeyString = cacheKey as String

    if let cachedImage = cache.object(forKey: cacheKey) {
      return cachedImage
    }

    if let existingTask = await taskStore.task(for: cacheKeyString) {
      if let image = try? await existingTask.value {
        return image
      }
    }

    let task = Task<PlatformImage?, Error> { [weak self] in
      guard let self else { return nil }

      var attempt = 0
      while true {
        do {
          try Task.checkCancellation()

          let resolvedURL: URL?
          if let avatarURL {
            resolvedURL = avatarURL
          } else if let did, let client {
            resolvedURL = try await self.resolveProfileAvatarURL(for: did, client: client)
          } else {
            resolvedURL = nil
          }

          if let resolvedURL, let image = try await self.fetchImage(from: resolvedURL, size: size) {
            self.cache.setObject(image, forKey: cacheKey)
            return image
          }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          self.logger.debug("Avatar load failed for \(did ?? "unknown"): \(String(describing: error))")
        }

        guard attempt < self.maxRetryAttempts else { break }
        let delay = self.backoffDelay(for: attempt)
        try await Task.sleep(nanoseconds: delay)
        attempt += 1
      }

      return nil
    }

    await taskStore.set(task, for: cacheKeyString)

    do {
      let image = try await task.value
      await taskStore.remove(for: cacheKeyString)
      return image
    } catch is CancellationError {
      await taskStore.remove(for: cacheKeyString)
      return nil
    } catch {
      await taskStore.remove(for: cacheKeyString)
      self.logger.debug("Avatar load aborted after retries for \(did ?? "unknown"): \(String(describing: error))")
      return nil
    }
  }
}

#if os(iOS)
  struct UIKitAvatarView: UIViewRepresentable {
    let did: String?
    let client: ATProtoClient?
    let size: CGFloat
    let avatarURL: URL?

    final class Coordinator {
      var loadTask: Task<Void, Never>?
      var requestID = UUID()
    }

    init(did: String?, client: ATProtoClient?, size: CGFloat = 24, avatarURL: URL? = nil) {
      self.did = did
      self.client = client
      self.size = size
      self.avatarURL = avatarURL
    }

    func makeCoordinator() -> Coordinator {
      Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
      // Container view to isolate layout
      let container = UIView()
      container.translatesAutoresizingMaskIntoConstraints = false

      // Image view
      let imageView = UIImageView()
      imageView.contentMode = .scaleAspectFill
      imageView.clipsToBounds = true
      imageView.translatesAutoresizingMaskIntoConstraints = false
      imageView.tag = 100  // Tag to find it easily

      container.addSubview(imageView)

      // Set explicit size constraints on the container
      NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: size),
        container.heightAnchor.constraint(equalToConstant: size),

        // Pin image view to container edges
        imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        imageView.topAnchor.constraint(equalTo: container.topAnchor),
        imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      ])

      // Set high priority on container to prevent expansion
      container.setContentHuggingPriority(.required, for: .horizontal)
      container.setContentHuggingPriority(.required, for: .vertical)
      container.setContentCompressionResistancePriority(.required, for: .horizontal)
      container.setContentCompressionResistancePriority(.required, for: .vertical)

      // Set placeholder image
      let placeholder = PlatformImage.systemImage(named: "person.crop.circle.fill")
      imageView.image = placeholder
      #if os(iOS)
        imageView.tintColor = UIColor.secondaryLabel
      #endif

      return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize {
      CGSize(width: size, height: size)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
      guard let imageView = uiView.subviews.first(where: { $0 is UIImageView }) as? UIImageView
      else {
        return
      }

      context.coordinator.loadTask?.cancel()
      let placeholder = PlatformImage.systemImage(named: "person.crop.circle.fill")

      imageView.layer.cornerRadius = size / 2
      imageView.tintColor = UIColor.secondaryLabel

      // Reset to placeholder if no DID and no direct URL
      guard did != nil || avatarURL != nil else {
        imageView.image = placeholder
        return
      }

      let requestID = UUID()
      context.coordinator.requestID = requestID

      context.coordinator.loadTask = Task {
        let image = await AvatarImageLoader.shared.loadAvatar(
          did: did,
          client: client,
          avatarURL: avatarURL,
          size: size
        )

        await MainActor.run {
          guard context.coordinator.requestID == requestID else { return }

          UIView.transition(
            with: imageView,
            duration: 0.3,
            options: .transitionCrossDissolve
          ) {
            imageView.image = image ?? placeholder
          }
        }
      }
    }
  }
#elseif os(macOS)
  struct NSKitAvatarView: NSViewRepresentable {
    let did: String?
    let client: ATProtoClient?
    let size: CGFloat
    let avatarURL: URL?

    final class Coordinator {
      var loadTask: Task<Void, Never>?
      var requestID = UUID()
    }

    init(did: String?, client: ATProtoClient?, size: CGFloat = 24, avatarURL: URL? = nil) {
      self.did = did
      self.client = client
      self.size = size
      self.avatarURL = avatarURL
    }

    func makeCoordinator() -> Coordinator {
      Coordinator()
    }

    func makeNSView(context: Context) -> NSImageView {
      let imageView = NSImageView()
      imageView.imageScaling = .scaleProportionallyUpOrDown
      imageView.wantsLayer = true
      imageView.layer?.cornerRadius = size / 2
      imageView.layer?.masksToBounds = true

      // Disable autoresizing mask and use constraints
      imageView.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        imageView.widthAnchor.constraint(equalToConstant: size),
        imageView.heightAnchor.constraint(equalToConstant: size),
      ])

      // Set placeholder image
      if #available(macOS 11.0, *) {
        let placeholder = NSImage(
          systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
        imageView.image = placeholder
      } else {
        // Fallback for older macOS versions
        imageView.image = NSImage(named: "person.crop.circle.fill")
      }

      return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
      context.coordinator.loadTask?.cancel()
      nsView.layer?.cornerRadius = size / 2

      let placeholder: NSImage?
      if #available(macOS 11.0, *) {
        placeholder = NSImage(
          systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
      } else {
        placeholder = NSImage(named: "person.crop.circle.fill")
      }

      // Reset to placeholder if no DID and no direct URL
      guard did != nil || avatarURL != nil else {
        nsView.image = placeholder
        return
      }

      let requestID = UUID()
      context.coordinator.requestID = requestID

      context.coordinator.loadTask = Task {
        let image = await AvatarImageLoader.shared.loadAvatar(
          did: did,
          client: client,
          avatarURL: avatarURL,
          size: size
        )

        await MainActor.run {
          guard context.coordinator.requestID == requestID else { return }

          if let image = image {
            NSAnimationContext.runAnimationGroup { context in
              context.duration = 0.3
              nsView.animator().image = image
            }
          } else {
            nsView.image = placeholder
          }
        }
      }
    }
  }
#endif

// MARK: - Cross-Platform Avatar View

/// Cross-platform avatar view that works on both iOS and macOS
public struct AvatarView: View {
  let did: String?
  let client: ATProtoClient?
  let size: CGFloat
  let avatarURL: URL?

  public init(did: String?, client: ATProtoClient?, size: CGFloat = 24, avatarURL: URL? = nil) {
    self.did = did
    self.client = client
    self.size = size
    self.avatarURL = avatarURL
  }

  public var body: some View {
    #if os(iOS)
      UIKitAvatarView(did: did, client: client, size: size, avatarURL: avatarURL)
    #elseif os(macOS)
      NSKitAvatarView(did: did, client: client, size: size, avatarURL: avatarURL)
    #else
      // Fallback for other platforms
      Circle()
        .fill(Color.gray.opacity(0.3))
        .frame(width: size, height: size)
        .overlay {
          Image(systemName: "person.crop.circle.fill")
            .foregroundColor(.secondary)
        }
    #endif
  }
}

// MARK: - Backward Compatibility

#if os(iOS)
  /// Make UIKitAvatarView globally available for backward compatibility
  typealias PlatformAvatarView = UIKitAvatarView
#elseif os(macOS)
  /// Make NSKitAvatarView globally available for backward compatibility
  typealias PlatformAvatarView = NSKitAvatarView
#endif
