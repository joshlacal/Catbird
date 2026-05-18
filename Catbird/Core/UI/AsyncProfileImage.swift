import SwiftUI
import NukeUI
import Nuke
import Petrel

private extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

enum AvatarModerationState {
    case show      // Show avatar normally
    case blur      // Show avatar blurred (tap to reveal)
    case hide      // Don't show avatar (placeholder only)
}

struct AsyncProfileImage: View {
    let url: URL?
    let size: CGFloat
    let labels: [ComAtprotoLabelDefs.Label]?
    private let imageRequest: ImageRequest?
    private let cachedImage: PlatformImage?

    @Environment(AppState.self) private var appState

    init(url: URL?, size: CGFloat, labels: [ComAtprotoLabelDefs.Label]? = nil) {
        self.url = url
        self.size = size
        self.labels = labels
        let request = Self.resizedRequest(for: url, sizeInPoints: size)
        self.imageRequest = request
        // Synchronous memory-cache probe: if the resized avatar is already in
        // the in-memory cache, paint it in init so the first frame is the
        // final image — no placeholder → fade transition for cache hits.
        if let request {
            self.cachedImage = ImageLoadingManager.shared.pipeline.cache[request]?.image
        } else {
            self.cachedImage = nil
        }
    }

    // Build a Nuke request that decodes at the exact pixel size to avoid large decode/scale costs.
    // Routes through ImageLoadingManager.cdnURL so Bluesky CDN avatars use JXL.
    private static func resizedRequest(for url: URL?, sizeInPoints: CGFloat) -> ImageRequest? {
        guard let url = url else { return nil }
        let scale = PlatformScreenInfo.scale
        let pixelDimension = max(1, (sizeInPoints * scale).rounded(.toNearestOrAwayFromZero))
        let pixelSize = CGSize(width: pixelDimension, height: pixelDimension)
        let processors: [any ImageProcessing] = [
            ImageProcessors.Resize(size: pixelSize, unit: .pixels, contentMode: .aspectFill)
        ]
        return ImageRequest(url: ImageLoadingManager.cdnURL(url), processors: processors, priority: .high)
    }
    
    private func getAvatarModerationState(_ labels: [ComAtprotoLabelDefs.Label]?) -> AvatarModerationState {
        guard let labels = labels, !labels.isEmpty else { return .show }
        
        // Check if any adult content labels present
        let hasAdultLabels = labels.contains { label in
            let lowercasedValue = label.val.lowercased()
            return ["porn", "nsfw", "nudity", "sexual"].contains(lowercasedValue)
        }
        
        guard hasAdultLabels else { return .show }
        
        // CRITICAL: If user is a minor (adult content disabled), HIDE the avatar completely
        if !appState.isAdultContentEnabled {
            return .hide
        }
        
        // User is an adult - check their granular preferences
        if let preferences = try? appState.preferencesManager.getLocalPreferences() {
            // Find the most restrictive setting among adult labels
            var mostRestrictive: ContentVisibility = .show
            
            for label in labels {
                let labelValue = label.val.lowercased()
                guard ["porn", "nsfw", "nudity", "sexual"].contains(labelValue) else { continue }
                
                // Map label to preference key
                let preferenceKey: String
                switch labelValue {
                case "porn", "nsfw", "sexual":
                    preferenceKey = "nsfw"
                case "nudity":
                    preferenceKey = "nudity"
                default:
                    preferenceKey = labelValue
                }
                
                // Get visibility for this label
                let visibility = ContentFilterManager.getVisibilityForLabel(
                    label: preferenceKey,
                    labelerDid: label.src,
                    preferences: preferences.contentLabelPrefs
                )
                
                // Track most restrictive
                switch (mostRestrictive, visibility) {
                case (_, .hide):
                    mostRestrictive = .hide
                case (.show, .warn):
                    mostRestrictive = .warn
                default:
                    break
                }
            }
            
            // Convert ContentVisibility to AvatarModerationState
            switch mostRestrictive {
            case .hide:
                return .hide
            case .warn:
                return .blur
            case .show:
                return .show
            }
        }
        
        // Fallback: if preferences unavailable for adult, blur by default (conservative)
        return .blur
    }
    
    var body: some View {
        let moderationState = getAvatarModerationState(labels)

        Group {
            if moderationState == .hide {
                Circle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        Image(systemName: "eye.slash.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundColor(.secondary.opacity(0.5))
                            .frame(width: size * 0.5, height: size * 0.5)
                    }
            } else if let cached = cachedImage {
                Image(platformImage: cached)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: moderationState == .blur ? 20 : 0)
            } else if let request = imageRequest {
                LazyImage(request: request) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity.animation(.easeOut(duration: 0.18)))
                    } else {
                        placeholder
                    }
                }
                .pipeline(ImageLoadingManager.shared.pipeline)
                .priority(.high)
                .blur(radius: moderationState == .blur ? 20 : 0)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    @ViewBuilder
    private var placeholder: some View {
        Circle()
            .fill(Color.gray.opacity(0.2))
            .overlay {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .foregroundColor(.accentColor.opacity(0.5))
                    .padding(size * 0.08)
            }
    }
}

#Preview {
  AsyncPreviewContent { appState in
    VStack(spacing: 20) {
            AsyncProfileImage(url: URL(string: "https://example.com/missing.jpg"), size: 40)
            AsyncProfileImage(url: URL(string: "https://avatars.githubusercontent.com/u/1?v=4"), size: 60)
            AsyncProfileImage(url: nil, size: 80)
        }
        .padding()
  }
}
