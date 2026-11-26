import NukeUI
import Petrel
import SwiftUI

struct FeedRowView: View {
    let feed: AppBskyFeedDefs.GeneratorView
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        HStack(spacing: 14) {
            if let avatarURL = feed.avatar {
                let url = URL(string: avatarURL.uriString())
                LazyImage(request: ImageRequestFactory.image(url, pointSize: CGSize(width: AvatarSize.lg, height: AvatarSize.lg), scale: displayScale)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.3))
                    }
                }
                .frame(width: AvatarSize.lg, height: AvatarSize.lg)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm.value, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: Radius.sm.value, style: .continuous)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: AvatarSize.lg, height: AvatarSize.lg)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(feed.displayName)
                    .appFont(AppTextRole.headline)
                    .lineLimit(1)

                Text("by @\(feed.creator.handle)", comment: "Feed creator attribution — %1$@ is the creator's handle (without @).")
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
                    Text("\(likeCount) likes", comment: "Number of likes on a custom feed — %1$lld is the like count.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.forward")
                .foregroundStyle(.secondary)
                .appFont(AppTextRole.caption)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
