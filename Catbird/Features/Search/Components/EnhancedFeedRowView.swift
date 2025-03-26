import SwiftUI
import Petrel
import NukeUI

/// Enhanced row view for displaying feed information in search results
struct EnhancedFeedRowView: View {
    let feed: AppBskyFeedDefs.GeneratorView
    
    var body: some View {
        HStack(spacing: 12) {
            // Feed avatar
            if let avatar = feed.avatar {
                LazyImage(url: URL(string: avatar.uriString())) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                // Placeholder
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "rectangle.grid.1x2")
                            .foregroundColor(Color.gray)
                    )
            }
            
            // Feed info
            VStack(alignment: .leading, spacing: 4) {
                Text(feed.displayName)
                    .font(.headline)
                    .lineLimit(1)
                
                    Text("By @\(feed.creator.handle)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                
                if let description = feed.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                
                // Stats
                if let likeCount = feed.likeCount {
                    HStack(spacing: 12) {
                        Label("\(formatCount(likeCount)) likes", systemImage: "heart")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal)
    }
    
    // Format count for display
    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let formatted = Double(count) / 1_000_000.0
            return String(format: "%.1fM", formatted)
        } else if count >= 1_000 {
            let formatted = Double(count) / 1_000.0
            return String(format: "%.1fK", formatted)
        } else {
            return "\(count)"
        }
    }
}
