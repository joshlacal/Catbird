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
                            } else if state.isLoading {
                                ProgressView()
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
                    
                    PostHeaderView(displayName: post.author.displayName ?? post.author.handle.description, handle: post.author.handle.description, timeAgo: formatTimeAgo(from: post.indexedAt.date))
                        .textScale(.secondary)
                    
                    Spacer()
                }
                
                // Post content
                if case let .knownType(record) = post.value,
                   let feedPost = record as? AppBskyFeedPost {
                    if !feedPost.text.isEmpty {
                        Text(feedPost.text)
                            .font(.body)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Add embed content if present
                    embeddedContent(for: post)
                }
                
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
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
    
    @ViewBuilder
    private func embeddedContent(for post: AppBskyEmbedRecord.ViewRecord) -> some View {
        if let embeds = post.embeds, !embeds.isEmpty {
            ForEach(embeds.indices, id: \.self) { index in
                switch embeds[index] {
                case .appBskyEmbedImagesView(let imageView):
                    ViewImageGridView(viewImages: imageView.images, shouldBlur: hasAdultContentLabel(labels))
                        .padding(.top, 6)
                    
                case .appBskyEmbedExternalView(let external):
                    ExternalEmbedView(
                        external: external.external,
                        shouldBlur: hasAdultContentLabel(labels),
                        postID: postID
                    )
                    .padding(.top, 6)
                    
                case .appBskyEmbedVideoView(let video):
                    if let playerView = ModernVideoPlayerView(
                        bskyVideo: video,
                        postID: postID
                    ) {
                        playerView
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 6)
                    }
                    
                case .appBskyEmbedRecordView(let record):
                    // For a record within a record, we'll just show a minimal reference
                    // without creating another nested embed
                    
                    switch record.record {
                    case .appBskyEmbedRecordViewRecord(let viewRecord):
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "chevron.right.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                
                                    
                                
                                Text("Quoting @\(viewRecord.author.handle)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.secondary)
                                
                                Image(systemName: "quote.bubble")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textScale(.secondary)
                                
                                //                            if case let .knownType(postRecord) = viewRecord.value,
                                //                               let feedPost = postRecord as? AppBskyFeedPost,
                                //                               !feedPost.text.isEmpty {
                                //                                Text(feedPost.text)
                                //                                    .font(.caption2)
                                //                                    .foregroundStyle(.secondary)
                                //                                    .lineLimit(2)
                                //                            }
                            }
                        }
                        .padding(.top, 6)
                    case .appBskyEmbedRecordViewNotFound:
                        Text("Quoting a deleted post")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    case .appBskyEmbedRecordViewBlocked:
                        Text("Quoting a blocked post")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    case .appBskyFeedDefsGeneratorView(let generator):
                        Text("Quoting feed: \(generator.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    case .appBskyGraphDefsListView(let list):
                        Text("Quoting list: \(list.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    default:
                        Text("Quoting content")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
                    // For record with media, we prioritize showing the media
                    VStack(spacing: 8) {
                        // Display the media portion
                        switch recordWithMediaView.media {
                        case .appBskyEmbedImagesView(let imagesView):
                            ViewImageGridView(
                                viewImages: imagesView.images,
                                shouldBlur: hasAdultContentLabel(labels)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 6)
                            
                        case .appBskyEmbedExternalView(let externalView):
                            ExternalEmbedView(
                                external: externalView.external,
                                shouldBlur: hasAdultContentLabel(labels),
                                postID: "\(postID)-embedded"
                            )
                            .padding(.top, 6)
                            
                        case .appBskyEmbedVideoView(let videoView):
                            if let playerView = ModernVideoPlayerView(
                                bskyVideo: videoView,
                                postID: "\(postID)-embedded-\(videoView.cid)"
                            ) {
                                playerView
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .padding(.top, 6)
                            }
                            
                        case .unexpected:
                            EmptyView()
                        }
                    }
                    
                case .unexpected(_):
                    // Simple fallback for unexpected content
                    Text("Unsupported content")
                        .font(.caption)
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
        .background(Color(.secondarySystemBackground))
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
        .background(Color(.secondarySystemBackground))
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
        .background(Color(.secondarySystemBackground))
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
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            
            if let description = generator.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
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
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            
            if let description = list.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
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
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    // MARK: - Helper Methods
    
    /// Determines if the post has adult content labels.
    private func hasAdultContentLabel(_ labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
        return labels?.contains { label in
            let value = label.val.lowercased()
            return value == "porn" || value == "nsfw" || value == "nudity"
        } ?? false
    }
}
