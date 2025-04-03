import UIKit
import SwiftUI

class AvatarImageLoader {
    static let shared = AvatarImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private var loadingTasks: [String: Task<UIImage?, Error>] = [:]
    
    func clearCache() {
        cache.removeAllObjects()
    }
    
    func loadAvatar(for did: String, client: ATProtoClient?, completion: @escaping (UIImage?) -> Void) {
        // Check cache first
        let cacheKey = NSString(string: "avatar-\(did)")
        if let cachedImage = cache.object(forKey: cacheKey) {
            completion(cachedImage)
            return
        }
        
        // Cancel any existing task for this DID
        loadingTasks[did]?.cancel()
        
        // Start new loading task
        let task = Task {
            do {
                guard let client = client else {
                    return nil
                }
                
                // Fetch profile
                let profile = try await client.app.bsky.actor.getProfile(
                    input: .init(actor: ATIdentifier(string: did))
                ).data
                
                // Download avatar if available
                if let avatarURLString = profile.avatar?.url?.absoluteString,
                   let avatarURL = URL(string: avatarURLString) {
                    
                    let (data, _) = try await URLSession.shared.data(from: avatarURL)
                    if let image = UIImage(data: data) {
                        // Cache the result
                        self.cache.setObject(image, forKey: cacheKey)
                        return image
                    }
                }
                return nil
            } catch {
                print("Avatar loading error: \(error)")
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
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = size / 2
        
        // Set placeholder image
        imageView.image = UIImage(systemName: "person.crop.circle.fill")
        imageView.tintColor = UIColor.secondaryLabel
        
        return imageView
    }
    
    func updateUIView(_ uiView: UIImageView, context: Context) {
        // Reset to placeholder if no DID
        guard let did = did else {
            uiView.image = UIImage(systemName: "person.crop.circle.fill")
            return
        }
        
        // Load avatar
        AvatarImageLoader.shared.loadAvatar(for: did, client: client) { image in
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