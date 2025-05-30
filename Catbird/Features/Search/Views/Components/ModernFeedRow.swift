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
                    .font(.headline)
                
                Text("by @\(feed.creator.handle)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if let description = feed.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
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
    // Placeholder for preview
    VStack {
        Text("Feed Row Preview")
            .font(.headline)
            .padding()
    }
}
