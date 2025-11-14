//
//  AvatarImageLoader.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/30/25.
//

#if os(iOS)
import UIKit
import Nuke
#elseif os(macOS)
import AppKit
#endif
import SwiftUI
import Petrel
import OSLog

private let avatarLogger = Logger(subsystem: "blue.catbird", category: "AvatarImageLoader")

// MARK: - Cross-Platform Image Extensions

extension PlatformImage {
    // Prefer the centralized implementation in CrossPlatformImage.swift.
    // Keep this as a thin adapter to the shared API name to avoid duplication.
    func circularCropped(to size: CGSize) -> PlatformImage? {
        return self.circularCroppedImage(to: size)
    }
}

class AvatarImageLoader {
    static let shared = AvatarImageLoader()
    private let cache = NSCache<NSString, PlatformImage>()
    private var loadingTasks: [String: Task<PlatformImage?, Error>] = [:]
    
    func clearCache() {
        cache.removeAllObjects()
    }
    
    // Helper method to resize images
    private func resizeImage(_ image: PlatformImage, to size: CGSize) -> PlatformImage? {
        return image.circularCroppedImage(to: size)
    }
    
    func loadAvatar(for did: String, client: ATProtoClient?, size: CGFloat = 24, completion: @escaping (PlatformImage?) -> Void) {
        // Use size-specific cache key
        let cacheKey = NSString(string: "avatar-\(did)-\(size)")
        avatarLogger.debug("[AVATAR] 🔍 Looking for cached avatar - DID: \(did.prefix(20))..., size: \(size)")

        if let cachedImage = cache.object(forKey: cacheKey) {
            avatarLogger.info("[AVATAR] ✅ Cache hit for DID: \(did.prefix(20))..., size: \(size)")
            completion(cachedImage)
            return
        }

        avatarLogger.debug("[AVATAR] ❌ Cache miss, will fetch from server")

        // Cancel any existing task for this DID
        loadingTasks[did]?.cancel()

        // Start new loading task
        let task = Task<PlatformImage?, Error> {
            do {
                guard let client = client else {
                    avatarLogger.error("[AVATAR] ❌ Client is nil, cannot load avatar for DID: \(did.prefix(20))...")
                    return nil as PlatformImage?
                }

                avatarLogger.debug("[AVATAR] 📡 Fetching profile for avatar - DID: \(did.prefix(20))...")

                // Fetch profile
                let profile = try await client.app.bsky.actor.getProfile(
                    input: .init(actor: try ATIdentifier(string: did))
                ).data
                
                // Download avatar if available using Nuke (off-main decode + caching)
                if let avatarURL = profile?.finalAvatarURL() {
                    avatarLogger.info("[AVATAR] 🌐 Found avatar URL: \(avatarURL.absoluteString)")
                    #if os(iOS)
                    avatarLogger.debug("[AVATAR] 📥 Downloading image with Nuke...")
                    let request = ImageRequest(url: avatarURL)
                    let response = try await ImagePipeline.shared.image(for: request)
                    let image = response
                    avatarLogger.debug("[AVATAR] ✅ Image downloaded, size: \(image.size.debugDescription)")
                    // Cache the rounded result for consistent reuse
                    let targetSize = CGSize(width: size, height: size)
                    if let rounded = image.circularCroppedImage(to: targetSize) {
                        self.cache.setObject(rounded, forKey: cacheKey)
                        avatarLogger.info("[AVATAR] 💾 Cached rounded avatar for DID: \(did.prefix(20))...")
                        return rounded
                    } else {
                        self.cache.setObject(image, forKey: cacheKey)
                        avatarLogger.info("[AVATAR] 💾 Cached original avatar for DID: \(did.prefix(20))...")
                        return image
                    }
                    #else
                    avatarLogger.debug("[AVATAR] 📥 Downloading image with URLSession...")
                    let (data, _) = try await URLSession.shared.data(from: avatarURL)
                    if let image = PlatformImage(data: data) {
                        avatarLogger.debug("[AVATAR] ✅ Image downloaded, size: \(data.count) bytes")
                        let sizeToUse = CGSize(width: size, height: size)
                        if let resizedImage = self.resizeImage(image, to: sizeToUse) {
                            self.cache.setObject(resizedImage, forKey: cacheKey)
                            avatarLogger.info("[AVATAR] 💾 Cached resized avatar for DID: \(did.prefix(20))...")
                            return resizedImage
                        } else {
                            self.cache.setObject(image, forKey: cacheKey)
                            avatarLogger.info("[AVATAR] 💾 Cached original avatar for DID: \(did.prefix(20))...")
                            return image
                        }
                    }
                    #endif
                } else {
                    avatarLogger.warning("[AVATAR] ⚠️ No avatar URL found in profile for DID: \(did.prefix(20))...")
                }
                return nil as PlatformImage?
            } catch {
                avatarLogger.error("[AVATAR] ❌ Avatar loading error: \(error.localizedDescription)")
                return nil as PlatformImage?
            }
        }
        
        loadingTasks[did] = task

        // Handle completion
        Task {
            do {
                let image = try await task.value
                if image != nil {
                    avatarLogger.info("[AVATAR] ✅ Avatar loaded successfully for DID: \(did.prefix(20))...")
                } else {
                    avatarLogger.warning("[AVATAR] ⚠️ Avatar loaded but image is nil for DID: \(did.prefix(20))...")
                }
                DispatchQueue.main.async {
                    avatarLogger.debug("[AVATAR] 🎨 Calling completion handler on main thread")
                    completion(image)
                }
            } catch {
                avatarLogger.error("[AVATAR] ❌ Task failed with error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }
}

#if os(iOS)
struct UIKitAvatarView: UIViewRepresentable {
    let did: String?
    let client: ATProtoClient?
    let size: CGFloat
    let avatarURL: URL?
    
    init(did: String?, client: ATProtoClient?, size: CGFloat = 24, avatarURL: URL? = nil) {
        self.did = did
        self.client = client
        self.size = size
        self.avatarURL = avatarURL
    }
    
    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true

        // Disable autoresizing mask to ensure SwiftUI frame is respected
        imageView.translatesAutoresizingMaskIntoConstraints = false

        // Set explicit size constraints to prevent toolbar from stretching
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: size),
            imageView.heightAnchor.constraint(equalToConstant: size)
        ])

        // Set placeholder image
        let placeholder = PlatformImage.systemImage(named: "person.crop.circle.fill")
        imageView.image = placeholder
        #if os(iOS)
        imageView.tintColor = UIColor.secondaryLabel
        #endif

        return imageView
    }
    
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize {
        return CGSize(width: size, height: size)
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        // Update corner radius for circular clipping
        uiView.layer.cornerRadius = size / 2

        avatarLogger.debug("[AVATAR] 🔄 UIKitAvatarView.updateUIView called - DID: \(did ?? "nil"), avatarURL: \(avatarURL?.absoluteString ?? "nil")")

        // Reset to placeholder if no DID and no direct URL
        guard did != nil || avatarURL != nil else {
            avatarLogger.warning("[AVATAR] ⚠️ No DID and no avatarURL, showing placeholder")
            uiView.image = PlatformImage.systemImage(named: "person.crop.circle.fill")
            return
        }

        // Prefer direct avatarURL when available (avoids extra profile fetch)
        if let directURL = avatarURL {
            avatarLogger.info("[AVATAR] 🌐 Loading from direct URL: \(directURL.absoluteString)")
            let request = ImageRequest(url: directURL)
            ImagePipeline.shared.loadImage(with: request) { result in
                switch result {
                case .success(let response):
                    let image = response.image
                    avatarLogger.info("[AVATAR] ✅ Direct URL image loaded successfully")
                    DispatchQueue.main.async {
                        UIView.transition(with: uiView, duration: 0.25, options: .transitionCrossDissolve) {
                            uiView.image = image
                        }
                        avatarLogger.debug("[AVATAR] 🎨 UIImageView updated with avatar")
                    }
                case .failure(let error):
                    avatarLogger.error("[AVATAR] ❌ Direct URL loading failed: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        uiView.image = PlatformImage.systemImage(named: "person.crop.circle.fill")
                    }
                }
            }
            return
        }

        // Fallback: load via DID using profile fetch
        if let did = did {
            avatarLogger.debug("[AVATAR] 🔄 Falling back to DID-based loading for: \(did.prefix(20))...")
            AvatarImageLoader.shared.loadAvatar(for: did, client: client, size: size) { image in
                if let image = image {
                    avatarLogger.info("[AVATAR] ✅ DID-based avatar loaded successfully")
                    UIView.transition(with: uiView, duration: 0.3, options: .transitionCrossDissolve) {
                        uiView.image = image
                    }
                    avatarLogger.debug("[AVATAR] 🎨 UIImageView updated with avatar")
                } else {
                    avatarLogger.warning("[AVATAR] ⚠️ DID-based loading returned nil, showing placeholder")
                    uiView.image = PlatformImage.systemImage(named: "person.crop.circle.fill")
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

    init(did: String?, client: ATProtoClient?, size: CGFloat = 24, avatarURL: URL? = nil) {
        self.did = did
        self.client = client
        self.size = size
        self.avatarURL = avatarURL
    }

    func makeNSView(context: Context) -> NSImageView {
        let imageView = NSImageView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = size / 2
        imageView.layer?.masksToBounds = true

        // Set placeholder image
        if #available(macOS 11.0, *) {
            let placeholder = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
            imageView.image = placeholder
        } else {
            // Fallback for older macOS versions
            imageView.image = NSImage(named: "person.crop.circle.fill")
        }

        return imageView
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        // Set frame explicitly
        nsView.frame = CGRect(x: 0, y: 0, width: size, height: size)

        // Reset to placeholder if no DID and no direct URL
        guard did != nil || avatarURL != nil else {
            if #available(macOS 11.0, *) {
                nsView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
            } else {
                nsView.image = NSImage(named: "person.crop.circle.fill")
            }
            return
        }

        // Prefer direct avatarURL when available (avoids extra profile fetch)
        if let directURL = avatarURL {
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: directURL)
                    if let image = NSImage(data: data) {
                        DispatchQueue.main.async {
                            NSAnimationContext.runAnimationGroup { context in
                                context.duration = 0.25
                                nsView.animator().image = image
                            }
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        if #available(macOS 11.0, *) {
                            nsView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
                        } else {
                            nsView.image = NSImage(named: "person.crop.circle.fill")
                        }
                    }
                }
            }
            return
        }

        // Fallback: load via DID using profile fetch
        if let did = did {
            AvatarImageLoader.shared.loadAvatar(for: did, client: client, size: size) { image in
                DispatchQueue.main.async {
                    if let image = image {
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = 0.3
                            nsView.animator().image = image
                        }
                    } else {
                        if #available(macOS 11.0, *) {
                            nsView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
                        } else {
                            nsView.image = NSImage(named: "person.crop.circle.fill")
                        }
                    }
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
