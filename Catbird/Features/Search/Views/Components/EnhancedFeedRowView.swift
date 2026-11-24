import SwiftUI
import Petrel
import NukeUI

/// Enhanced row view for displaying feed information in search results
struct EnhancedFeedRowView: View {
    let feed: AppBskyFeedDefs.GeneratorView
    @Environment(\.displayScale) private var displayScale
    @Environment(\.locale) private var locale
    
    var body: some View {
        HStack(spacing: 12) {
            // Feed avatar
            if let avatar = feed.avatar,
               let url = URL(string: avatar.uriString()) {
                LazyImage(request: ImageRequestFactory.image(url, pointSize: 44, scale: displayScale, contentMode: .aspectFill)) { state in
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
                    .appFont(AppTextRole.headline)
                    .lineLimit(1)
                
                    Text(
                        "By @\(feed.creator.handle.description)",
                        comment: "Feed creator attribution in search results — variable is the creator's handle"
                    )
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.secondary)
                
                if let description = feed.description, !description.isEmpty {
                    Text(description)
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
                
                // Stats
                if let likeCount = feed.likeCount {
                    HStack(spacing: 12) {
                        Label {
                            if likeCount >= 1_000 {
                                Text(
                                    "\(formatCount(likeCount)) likes",
                                    comment: "Compact like count (e.g. 1.2K likes) on a custom feed in search results"
                                )
                            } else {
                                Text(
                                    "\(likeCount) likes",
                                    comment: "Like count on a custom feed in search results"
                                )
                            }
                        } icon: {
                            Image(systemName: "heart")
                        }
                        .appFont(AppTextRole.caption2)
                        .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
            
            Spacer()
            
            Image(systemName: "chevron.forward")
                .appFont(AppTextRole.footnote)
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

#Preview("Enhanced Feed Row") {
  AsyncPreviewDataContent { appState in
    await PreviewData.popularFeeds(from: appState).first
  } content: { _, feed in
    List {
      EnhancedFeedRowView(feed: feed)
    }
  }
}
