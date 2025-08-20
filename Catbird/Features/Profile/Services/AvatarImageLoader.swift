//
//  AvatarImageLoader.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/30/25.
//

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import SwiftUI
import Petrel
import OSLog

private let avatarLogger = Logger(subsystem: "blue.catbird", category: "AvatarImageLoader")

// MARK: - Cross-Platform Image Extensions

extension PlatformImage {
    func circularCropped(to size: CGSize) -> PlatformImage? {
        #if os(iOS)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            // Draw a path to clip to a circular shape
            let path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size))
            path.addClip()
            
            // Calculate scaling to fill the circle
            let aspectWidth = size.width / self.size.width
            let aspectHeight = size.height / self.size.height
            let aspectRatio = max(aspectWidth, aspectHeight)
            
            let scaledWidth = self.size.width * aspectRatio
            let scaledHeight = self.size.height * aspectRatio
            let drawingRect = CGRect(
                x: (size.width - scaledWidth) / 2,
                y: (size.height - scaledHeight) / 2,
                width: scaledWidth,
                height: scaledHeight
            )
            
            self.draw(in: drawingRect)
        }
        #elseif os(macOS)
        return NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                avatarLogger.error("Failed to get current graphics context")
                return false
            }
            
            // Create circular clipping path
            let path = NSBezierPath(ovalIn: rect)
            path.addClip()
            
            // Calculate scaling to fill the circle
            let aspectWidth = size.width / self.size.width
            let aspectHeight = size.height / self.size.height
            let aspectRatio = max(aspectWidth, aspectHeight)
            
            let scaledWidth = self.size.width * aspectRatio
            let scaledHeight = self.size.height * aspectRatio
            let drawingRect = CGRect(
                x: (size.width - scaledWidth) / 2,
                y: (size.height - scaledHeight) / 2,
                width: scaledWidth,
                height: scaledHeight
            )
            
            self.draw(in: drawingRect)
            return true
        }
        #endif
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
        return image.circularCropped(to: size)
    }
    
    func loadAvatar(for did: String, client: ATProtoClient?, size: CGFloat = 24, completion: @escaping (PlatformImage?) -> Void) {
        // Use size-specific cache key
        let cacheKey = NSString(string: "avatar-\(did)-\(size)")
        if let cachedImage = cache.object(forKey: cacheKey) {
            completion(cachedImage)
            return
        }
        
        // Cancel any existing task for this DID
        loadingTasks[did]?.cancel()
        
        // Start new loading task
        let task = Task<PlatformImage?, Error> {
            do {
                guard let client = client else {
                    avatarLogger.debug("Client is nil, cannot load avatar for DID: \(did)")
                    return nil
                }
                
                // Fetch profile
                let profile = try await client.app.bsky.actor.getProfile(
                    input: .init(actor: ATIdentifier(string: did))
                ).data
                
                // Download avatar if available
                if let avatarURL = profile?.finalAvatarURL() {
                    
                    let (data, _) = try await URLSession.shared.data(from: avatarURL)
                    if let image = PlatformImage(data: data) {
                        // Resize image before caching
                        let sizeToUse = CGSize(width: size, height: size)
                        if let resizedImage = self.resizeImage(image, to: sizeToUse) {
                            // Cache the resized result
                            self.cache.setObject(resizedImage, forKey: cacheKey)
                            return resizedImage
                        }
                    }
                }
                return nil
            } catch {
                avatarLogger.debug("Avatar loading error: \(error)")
                return nil
            }
        }
        
        loadingTasks[did] = task
        
        // Handle completion
        Task {
            do {
                let image = try await task.value
                DispatchQueue.main.async {
                    completion(image)
                }
            } catch {
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
    
    init(did: String?, client: ATProtoClient?, size: CGFloat = 24) {
        self.did = did
        self.client = client
        self.size = size
    }
    
    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        // Change to scaleAspectFill to ensure the image fills the circular area
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = size / 2
        
        // Set placeholder image
        let placeholder = UIImage(systemName: "person.crop.circle.fill")
        imageView.image = placeholder
        imageView.tintColor = UIColor.secondaryLabel
        
        return imageView
    }
    
    func updateUIView(_ uiView: UIImageView, context: Context) {
        // Set frame explicitly
        uiView.frame = CGRect(x: 0, y: 0, width: size, height: size)
        
        // Reset to placeholder if no DID
        guard let did = did else {
            uiView.image = UIImage(systemName: "person.crop.circle.fill")
            return
        }
        
        // Load avatar
        AvatarImageLoader.shared.loadAvatar(for: did, client: client, size: size) { image in
            if let image = image {
                UIView.transition(with: uiView, duration: 0.3, options: .transitionCrossDissolve) {
                    uiView.image = image
                }
            } else {
                uiView.image = UIImage(systemName: "person.crop.circle.fill")
            }
        }
    }
}
#elseif os(macOS)
struct NSKitAvatarView: NSViewRepresentable {
    let did: String?
    let client: ATProtoClient?
    let size: CGFloat
    
    init(did: String?, client: ATProtoClient?, size: CGFloat = 24) {
        self.did = did
        self.client = client
        self.size = size
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
        
        // Reset to placeholder if no DID
        guard let did = did else {
            if #available(macOS 11.0, *) {
                nsView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
            } else {
                nsView.image = NSImage(named: "person.crop.circle.fill")
            }
            return
        }
        
        // Load avatar
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
#endif

// MARK: - Cross-Platform Avatar View

/// Cross-platform avatar view that works on both iOS and macOS
public struct AvatarView: View {
    let did: String?
    let client: ATProtoClient?
    let size: CGFloat
    
    public init(did: String?, client: ATProtoClient?, size: CGFloat = 24) {
        self.did = did
        self.client = client
        self.size = size
    }
    
    public var body: some View {
        #if os(iOS)
        UIKitAvatarView(did: did, client: client, size: size)
        #elseif os(macOS)
        NSKitAvatarView(did: did, client: client, size: size)
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