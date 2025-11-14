import SwiftUI
import Petrel
import NukeUI

struct ModernFeedRow: View {
    let feed: AppBskyFeedDefs.GeneratorView
    
    var body: some View {
        HStack(spacing: 14) {
            // Feed image
            ProfileImageView(url: URL(string: feed.avatar?.uriString() ?? ""), size: 50)
            
            // Feed info
            VStack(alignment: .leading, spacing: 4) {
                Text(feed.displayName)
                    .appFont(AppTextRole.headline)
                
                Text("by @\(feed.creator.handle)")
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.secondary)
                
                if let description = feed.description, !description.isEmpty {
                    Text(description)
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            
            Spacer()
        }
    }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
    // Placeholder for preview
    VStack {
        Text("Feed Row Preview")
            .appFont(AppTextRole.headline)
            .padding()
    }
}
