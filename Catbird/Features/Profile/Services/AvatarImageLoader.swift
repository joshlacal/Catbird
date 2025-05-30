//
//  AvatarImageLoader.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/30/25.
//

import UIKit
import SwiftUI
import Petrel

class AvatarImageLoader {
    static let shared = AvatarImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private var loadingTasks: [String: Task<UIImage?, Error>] = [:]
    
    func clearCache() {
        cache.removeAllObjects()
    }
    
    // Helper method to resize images
    private func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            // Draw a path to clip to a circular shape
            let path = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size))
            path.addClip()
            
            // Calculate scaling to fill the circle
            let aspectWidth = size.width / image.size.width
            let aspectHeight = size.height / image.size.height
            let aspectRatio = max(aspectWidth, aspectHeight)
            
            let scaledWidth = image.size.width * aspectRatio
            let scaledHeight = image.size.height * aspectRatio
            let drawingRect = CGRect(
                x: (size.width - scaledWidth) / 2,
                y: (size.height - scaledHeight) / 2,
                width: scaledWidth,
                height: scaledHeight
            )
            
            image.draw(in: drawingRect)
        }
    }
    
    func loadAvatar(for did: String, client: ATProtoClient?, size: CGFloat = 24, completion: @escaping (UIImage?) -> Void) {
        // Use size-specific cache key
        let cacheKey = NSString(string: "avatar-\(did)-\(size)")
        if let cachedImage = cache.object(forKey: cacheKey) {
            completion(cachedImage)
            return
        }
        
        // Cancel any existing task for this DID
        loadingTasks[did]?.cancel()
        
        // Start new loading task
        let task = Task<UIImage?, Error> {
            do {
                guard let client = client else {
                    logger.debug("Client is nil, cannot load avatar for DID: \(did)")
                    return nil
                }
                
                // Fetch profile
                let profile = try await client.app.bsky.actor.getProfile(
                    input: .init(actor: ATIdentifier(string: did))
                ).data
                
                // Download avatar if available
                if let avatarURL = profile?.finalAvatarURL() {
                    
                    let (data, _) = try await URLSession.shared.data(from: avatarURL)
                    if let image = UIImage(data: data) {
                        // Resize image before caching
                        let sizeToUse = CGSize(width: size, height: size)
                        let resizedImage = self.resizeImage(image, to: sizeToUse)
                        
                        // Cache the resized result
                        self.cache.setObject(resizedImage, forKey: cacheKey)
                        return resizedImage
                    }
                }
                return nil
            } catch {
                logger.debug("Avatar loading error: \(error)")
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
