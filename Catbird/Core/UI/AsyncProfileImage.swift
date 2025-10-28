import SwiftUI
import NukeUI
import Nuke
import Petrel

enum AvatarModerationState {
    case show      // Show avatar normally
    case blur      // Show avatar blurred (tap to reveal)
    case hide      // Don't show avatar (placeholder only)
}

struct AsyncProfileImage: View {
    let url: URL?
    let size: CGFloat
    let labels: [ComAtprotoLabelDefs.Label]?
    
    @Environment(AppState.self) private var appState
    
    init(url: URL?, size: CGFloat, labels: [ComAtprotoLabelDefs.Label]? = nil) {
        self.url = url
        self.size = size
        self.labels = labels
    }
    
    // Build a Nuke request that decodes at the exact pixel size to avoid large decode/scale costs
    private func resizedRequest(for url: URL?, sizeInPoints: CGFloat) -> ImageRequest? {
        guard let url = url else { return nil }
        let scale = PlatformScreenInfo.scale
        let pixelSize = CGSize(width: sizeInPoints * scale, height: sizeInPoints * scale)
        let processors: [any ImageProcessing] = [
            ImageProcessors.Resize(size: pixelSize, unit: .pixels, contentMode: .aspectFill)
        ]
        return ImageRequest(url: url, processors: processors)
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
        
        ZStack {
            // Background placeholder
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: size, height: size)
            
            if moderationState == .hide {
                // Hidden: Show placeholder icon only (for minors or hide preference)
                Image(systemName: "eye.slash.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.secondary.opacity(0.5))
                    .frame(width: size * 0.5, height: size * 0.5)
            } else if let request = resizedRequest(for: url, sizeInPoints: size) {
                // Show avatar (blurred or not)
                LazyImage(request: request) { state in
                    if state.isLoading {
                        // Loading state
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                    } else if let image = state.image {
                        // Success state
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        // Failure state
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .foregroundColor(.accentColor.opacity(0.5))
                    }
                }
                .priority(.high)
                .frame(width: size, height: size)
                .clipShape(Circle())
                .blur(radius: moderationState == .blur ? 20 : 0)
            } else {
                // No URL provided
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .foregroundColor(.accentColor.opacity(0.5))
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        AsyncProfileImage(url: URL(string: "https://example.com/missing.jpg"), size: 40)
        AsyncProfileImage(url: URL(string: "https://avatars.githubusercontent.com/u/1?v=4"), size: 60)
        AsyncProfileImage(url: nil, size: 80)
    }
    .padding()
}
