import SwiftUI
import Petrel
import NukeUI
import Nuke

struct RecordEmbedView: View {
    let record: AppBskyEmbedRecord.ViewRecordUnion
    let labels: [ComAtprotoLabelDefs.Label]?
    @Binding var path: NavigationPath
    @Environment(\.postID) var postID
    @Environment(AppState.self) private var appState
    
    @State private var isExpanded = false
    
    var body: some View {
        switch record {
        case .appBskyEmbedRecordViewRecord(let post):
            postView(post)
        case .appBskyEmbedRecordViewNotFound:
            notFoundView
        case .appBskyEmbedRecordViewBlocked(let blocked):
            blockedView(blocked)
        case .appBskyEmbedRecordViewDetached(let detached):
            detachedView(detached)
        case .appBskyFeedDefsGeneratorView(let generator):
            generatorView(generator)
        case .appBskyGraphDefsListView(let list):
            listView(list)
        case .appBskyLabelerDefsLabelerView(let labeler):
            LabelerView(labeler: labeler)
        case .appBskyGraphDefsStarterPackViewBasic(let starterPack):
                StarterPackCardView(starterPack: starterPack, path: $path)
                    .padding(.vertical, 4)
        case .unexpected:
            unsupportedView
        }
    }
    
    @ViewBuilder
    private func postView(_ post: AppBskyEmbedRecord.ViewRecord) -> some View {
        Button {
            path.append(NavigationDestination.post(post.uri))
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Author info
                HStack(spacing: 8) {
                    if let avatarURL = post.author.finalAvatarURL() {
                        LazyImage(url: avatarURL) { state in
                            if let image = state.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "person.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .pipeline(ImageLoadingManager.shared.pipeline)
                        .priority(.high)
                        .processors([
                          ImageProcessors.AsyncImageDownscaling(targetSize: CGSize(width: 20, height: 20))
                        ])
                        .frame(width: 20, height: 20)
                        .clipShape(Circle())
                    }
                    
                    PostHeaderView(displayName: post.author.displayName ?? post.author.handle.description, handle: post.author.handle.description, timeAgo: post.indexedAt.date)
                        .textScale(.secondary)
                        .foregroundStyle(.primary)
                    
                    Spacer()
                }
                
                // Post content
                if case let .knownType(record) = post.value,
                   let feedPost = record as? AppBskyFeedPost {
                    if !feedPost.text.isEmpty {
                        Text(feedPost.text)
                            .appFont(AppTextRole.body)
                            .foregroundStyle(.primary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Add embed content if present
                    embeddedContent(for: post)
                }
                
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )

        }
        .buttonStyle(.plain)
        .onTapGesture {
            withAnimation {
                isExpanded.toggle()
            }
        }
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    // MARK: - Embedded Content
    
    /// Displays embedded content within a quoted post with proper content warnings
    /// 
    /// This method wraps all embedded media (images, videos, external links) with ContentLabelManager
    /// to ensure proper content moderation based on user preferences and content labels.
    /// 
    /// - Parameter post: The record containing embeds to display
    /// - Returns: A view containing the embedded content with appropriate content warnings
    @ViewBuilder
    private func embeddedContent(for post: AppBskyEmbedRecord.ViewRecord) -> some View {
        if let embeds = post.embeds, !embeds.isEmpty {
            ForEach(embeds.indices, id: \.self) { index in
                switch embeds[index] {
                case .appBskyEmbedImagesView(let imageView):
                    ContentLabelManager(
                        labels: labels,
                        contentType: "image"
                    ) {
                        ViewImageGridView(
                            viewImages: imageView.images,
                            shouldBlur: false // ContentLabelManager handles blurring
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 6)
                    
                case .appBskyEmbedExternalView(let external):
                    ContentLabelManager(
                        labels: labels,
                        contentType: "link"
                    ) {
                        ExternalEmbedView(
                            external: external.external,
                            shouldBlur: false, // ContentLabelManager handles content decisions
                            postID: postID
                        )
                    }
                    .padding(.top, 6)
                    
                case .appBskyEmbedVideoView(let video):
                    ContentLabelManager(
                        labels: labels,
                        contentType: "video"
                    ) {
                        if let playerView = ModernVideoPlayerView(
                            bskyVideo: video,
                            postID: postID
                        ) {
                            playerView
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Unable to load video")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 6)
                    
                case .appBskyEmbedRecordView(let record):
                    // For a record within a record, we'll just show a minimal reference
                    // without creating another nested embed
                    
                    switch record.record {
                    case .appBskyEmbedRecordViewRecord(let viewRecord):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "chevron.right.circle")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.secondary)
                                
                                Text("Quoting @\(viewRecord.author.handle)")
                                    .appFont(AppTextRole.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                
                                Image(systemName: "quote.bubble")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.secondary)
                                    .textScale(.secondary)
                                
                                //                            if case let .knownType(postRecord) = viewRecord.value,
                                //                               let feedPost = postRecord as? AppBskyFeedPost,
                                //                               !feedPost.text.isEmpty {
                                //                                Text(feedPost.text)
                                //                                    .appFont(AppTextRole.caption2)
                                //                                    .foregroundStyle(.secondary)
                                //                                    .lineLimit(2)
                                //                            }
                            }
                        }
                        .padding(.top, 6)
                    case .appBskyEmbedRecordViewNotFound:
                        Text("Quoting a deleted post")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    case .appBskyEmbedRecordViewBlocked:
                        Text("Quoting a blocked post")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    case .appBskyFeedDefsGeneratorView(let generator):
                        Text("Quoting feed: \(generator.displayName)")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    case .appBskyGraphDefsListView(let list):
                        Text("Quoting list: \(list.name)")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    default:
                        Text("Quoting content")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
                    // For record with media, we prioritize showing the media
                    VStack(spacing: 8) {
                        // Display the media portion
                        switch recordWithMediaView.media {
                        case .appBskyEmbedImagesView(let imagesView):
                            ContentLabelManager(
                                labels: labels,
                                contentType: "image"
                            ) {
                                ViewImageGridView(
                                    viewImages: imagesView.images,
                                    shouldBlur: false // ContentLabelManager handles blurring
                                )
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 6)
                            
                        case .appBskyEmbedExternalView(let externalView):
                            ContentLabelManager(
                                labels: labels,
                                contentType: "link"
                            ) {
                                ExternalEmbedView(
                                    external: externalView.external,
                                    shouldBlur: false, // ContentLabelManager handles content decisions
                                    postID: "\(postID)-embedded"
                                )
                            }
                            .padding(.top, 6)
                            
                        case .appBskyEmbedVideoView(let videoView):
                            ContentLabelManager(
                                labels: labels,
                                contentType: "video"
                            ) {
                                if let playerView = ModernVideoPlayerView(
                                    bskyVideo: videoView,
                                    postID: "\(postID)-embedded-\(videoView.cid)"
                                ) {
                                    playerView
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Unable to load video")
                                        .appFont(AppTextRole.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 6)
                            
                        case .unexpected:
                            EmptyView()
                        }
                    }
                    
                case .unexpected:
                    // Simple fallback for unexpected content
                    Text("Unsupported content")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
        }
    }
    private var notFoundView: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text("Post not found")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    @ViewBuilder
    private func blockedView(_ blocked: AppBskyEmbedRecord.ViewBlocked) -> some View {
        HStack {
            Image(systemName: "hand.raised")
            Text("Content blocked")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    @ViewBuilder
    private func detachedView(_ detached: AppBskyEmbedRecord.ViewDetached) -> some View {
        HStack {
            Image(systemName: "link.badge.plus")
            Text("Content unavailable")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    @ViewBuilder
    private func generatorView(_ generator: AppBskyFeedDefs.GeneratorView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "newspaper")
                    .foregroundColor(Color.accentColor)
                Text("Feed: \(generator.displayName)")
                    .appFont(AppTextRole.subheadline.weight(.medium))
                Spacer()
            }
            
            if let description = generator.description {
                Text(description)
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            path.append(NavigationDestination.feed(generator.uri))
        }
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    @ViewBuilder
    private func listView(_ list: AppBskyGraphDefs.ListView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "list.bullet")
                    .foregroundColor(.green)
                Text("List: \(list.name)")
                    .appFont(AppTextRole.subheadline.weight(.medium))
                Spacer()
            }
            
            if let description = list.description {
                Text(description)
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture {
            path.append(NavigationDestination.list(list.uri))
        }
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    private var unsupportedView: some View {
        HStack {
            Image(systemName: "questionmark.circle")
            Text("Unsupported content type")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    // MARK: - Helper Methods
    
    // Note: Content label handling is now managed by ContentLabelManager
    // which provides proper user preference integration and age-based restrictions
}
