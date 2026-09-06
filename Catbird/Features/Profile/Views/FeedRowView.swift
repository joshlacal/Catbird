import NukeUI
import Petrel
import SwiftUI

struct FeedRowView: View {
    let feed: AppBskyFeedDefs.GeneratorView

    var body: some View {
        HStack(spacing: 14) {
            if let avatarURL = feed.avatar {
                LazyImage(url: URL(string: avatarURL.uriString())) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                    }
                }
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 50, height: 50)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(feed.displayName)
                    .appFont(AppTextRole.headline)
                    .lineLimit(1)

                Text("by @\(feed.creator.handle)")
                    .appFont(AppTextRole.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let description = feed.description, !description.isEmpty {
                    Text(description)
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }

                if let likeCount = feed.likeCount, likeCount > 0 {
                    Text("\(likeCount) likes")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
                .appFont(AppTextRole.caption)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
