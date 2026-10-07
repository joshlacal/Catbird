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
    @Environment(\.isReadOnlyPostPreview) private var isReadOnlyPreview
    // When true, render full post styling for quoted posts (used in thread main post view)
    var useFullPostStyle: Bool = false
    /// Quotes from muted accounts stay collapsed until the viewer asks to see them.
    @State private var revealedMutedQuote: [String]?
    
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
            Button {
                path.append(NavigationDestination.profile(labeler.creator.did.didString()))
            } label: {
                LabelerView(labeler: labeler)
            }
            .buttonStyle(.plain)
            .modifier(ReadOnlyPostMediaModifier())
        case .appBskyGraphDefsStarterPackViewBasic(let starterPack):
                StarterPackCardView(starterPack: starterPack, path: $path)
                    .modifier(ReadOnlyPostMediaModifier())
                    .padding(.vertical, 4)
        case .unexpected:
            unsupportedView
        }
    }
    
    @ViewBuilder
    private func postView(_ post: AppBskyEmbedRecord.ViewRecord) -> some View {
        if isReadOnlyPreview && BlockRelationship(viewer: post.author.viewer).direction != .unknown {
            BlockedContentCard(
                relationship: BlockRelationship(viewer: post.author.viewer),
                authorDid: post.author.did.didString(),
                postUri: post.uri,
                variant: .embedCompact,
                path: $path
            )
        } else if post.author.viewer?.muted == true && !showsMutedQuote(post) {
            mutedQuoteView(for: post)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ContentLabelView(labels: post.labels, selfLabelValues: quotedSelfLabelValues(post),
                    subject: PostLabelSubject(uri: post.uri.uriString(), cid: post.cid,
                        authorDID: post.author.did.didString(), authorHandle: post.author.handle.description))
                quotedPostView(post)
                    .postRevealFade(isEnabled: showsMutedQuote(post))
                    .environment(\.postLabelSummaryIDs, PostLabelSubject(uri: post.uri.uriString(), cid: post.cid,
                        authorDID: post.author.did.didString(), authorHandle: post.author.handle.description).labelIDs(in: post.labels))
            }
        }
    }

    private func quotedSelfLabelValues(_ post: AppBskyEmbedRecord.ViewRecord) -> [String] {
        guard case .knownType(let record) = post.value, let feedPost = record as? AppBskyFeedPost,
              let labels = feedPost.labels,
              case .comAtprotoLabelDefsSelfLabels(let selfLabels) = labels else { return [] }
        return selfLabels.values.map(\.val)
    }

    private func mutedQuoteIdentity(_ post: AppBskyEmbedRecord.ViewRecord) -> [String] {
        [appState.userDID, post.uri.uriString(), post.cid.description]
    }

    private func showsMutedQuote(_ post: AppBskyEmbedRecord.ViewRecord) -> Bool {
        revealedMutedQuote == mutedQuoteIdentity(post)
    }

    private func mutedQuoteView(for post: AppBskyEmbedRecord.ViewRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.slash")
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)
            Text("Post from an account you muted")
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 0)
            Button("Show") {
                revealedMutedQuote = mutedQuoteIdentity(post)
            }
            .appFont(AppTextRole.subheadline)
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .feedEmbedCardStyle()
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Applies the quoted post's own labels to its text, the way a top-level post
    /// without media is covered. Media embeds apply the same labels themselves.
    @ViewBuilder
    private func labeledQuoteText<Content: View>(
        for post: AppBskyEmbedRecord.ViewRecord,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if (post.embeds ?? []).isEmpty, let labels = post.labels, !labels.isEmpty {
            ContentLabelManager(labels: labels, contentType: "post") {
                content()
            }
        } else {
            content()
        }
    }

    @ViewBuilder
    private func quotedPostView(_ post: AppBskyEmbedRecord.ViewRecord) -> some View {
        Group {
            if useFullPostStyle || isReadOnlyPreview {
                // Render a fuller post style with standard card background and let tap navigate
                VStack(alignment: .leading, spacing: 8) {
                    // Author row
                    HStack(spacing: 10) {
                        if let avatarURL = post.author.finalAvatarURL() {
                            LazyImage(request: ImageLoadingManager.imageRequest(
                                for: avatarURL,
                                targetSize: CGSize(width: 36, height: 36)
                            )) { state in
                                if let image = state.image {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    avatarPlaceholder(size: 36)
                                }
                            }
                            .pipeline(ImageLoadingManager.shared.pipeline)
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                        } else {
                            avatarPlaceholder(size: 36)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            EmbeddedAuthorNameView(
                                name: post.author.displayName ?? post.author.handle.description,
                                verification: post.author.verification,
                                isAutomated: AutomationBadge.isSelfDeclared(labels: post.author.labels, authorDID: post.author.did)
                            )
                                .appFont(AppTextRole.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("@\(post.author.handle.description)")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    // Text
                    if case let .knownType(record) = post.value,
                       let feedPost = record as? AppBskyFeedPost,
                       !feedPost.text.isEmpty {
                        labeledQuoteText(for: post) {
                            Text(feedPost.text)
                                .appFont(AppTextRole.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                        }
                    }
                    // Embeds
                    embeddedContent(for: post)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isReadOnlyPreview else { return }
                    path.append(NavigationDestination.post(post.uri))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .feedEmbedCardStyle()
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Button {
                    path.append(NavigationDestination.post(post.uri))
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        // Author info
                        HStack(spacing: 8) {
                            if let avatarURL = post.author.finalAvatarURL() {
                                LazyImage(request: ImageLoadingManager.imageRequest(
                                    for: avatarURL,
                                    targetSize: CGSize(width: 20, height: 20)
                                )) { state in
                                    if let image = state.image {
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    } else {
                                        avatarPlaceholder(size: 20)
                                    }
                                }
                                .pipeline(ImageLoadingManager.shared.pipeline)
                                .frame(width: 20, height: 20)
                                .clipShape(Circle())
                            } else {
                                avatarPlaceholder(size: 20)
                            }
                            
                            PostHeaderView(
                                displayName: post.author.displayName ?? post.author.handle.description,
                                handle: post.author.handle.description,
                                timeAgo: post.indexedAt.date,
                                verificationKind: VerificationBadge.metadataKind(for: post.author.verification),
                                isAutomated: AutomationBadge.isSelfDeclared(labels: post.author.labels, authorDID: post.author.did)
                            )
                                .textScale(.secondary)
                                .foregroundStyle(.primary)
                            
                            Spacer()
                        }
                        
                        // Post content
                        if case let .knownType(record) = post.value,
                           let feedPost = record as? AppBskyFeedPost {
                            if !feedPost.text.isEmpty {
                                labeledQuoteText(for: post) {
                                    Text(feedPost.text)
                                        .appFont(AppTextRole.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(nil)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            // Add embed content if present
                            embeddedContent(for: post)
                        }
                        
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .feedEmbedCardStyle()
                }
                .buttonStyle(.plain)
                // Use fixed sizing to prevent layout jumps
                .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                        labels: post.labels, // Use the embedded post's labels, not parent
                        contentType: "image"
                    ) {
                        ViewImageGridView(
                            viewImages: imageView.images,
                            shouldBlur: false // ContentLabelManager handles blurring
                        )
                        .modifier(ReadOnlyPostMediaModifier())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 6)

                case .appBskyEmbedGalleryView(let galleryView):
                    ContentLabelManager(
                        labels: post.labels, // Use the embedded post's labels, not parent
                        contentType: "image"
                    ) {
                        GalleryEmbedView(
                            gallery: galleryView,
                            shouldBlur: false // ContentLabelManager handles blurring
                        )
                        .modifier(ReadOnlyPostMediaModifier())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 6)

                case .appBskyEmbedExternalView(let external):
                    ContentLabelManager(
                        labels: post.labels, // Use the embedded post's labels, not parent
                        contentType: "link"
                    ) {
                        PostExternalEmbedContent(
                            external: external.external,
                            postID: postID
                        )
                    }
                    .padding(.top, 6)
                    
                case .appBskyEmbedVideoView(let video):
                    ContentLabelManager(
                        labels: post.labels, // Use the embedded post's labels, not parent
                        contentType: "video"
                    ) {
                        PostVideoEmbedContent(video: video, postID: postID)
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
                                
                                EmbeddedAuthorNameView(
                                    name: "Quoting @\(viewRecord.author.handle)",
                                    verification: viewRecord.author.verification,
                                    isAutomated: AutomationBadge.isSelfDeclared(labels: viewRecord.author.labels, authorDID: viewRecord.author.did)
                                )
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
                    case .appBskyEmbedRecordViewBlocked(let nestedBlocked):
                        blockedView(nestedBlocked)
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
                        Text("Quoting a post")
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
                                labels: post.labels, // Use the embedded post's labels, not parent
                                contentType: "image"
                            ) {
                                ViewImageGridView(
                                    viewImages: imagesView.images,
                                    shouldBlur: false // ContentLabelManager handles blurring
                                )
                                .modifier(ReadOnlyPostMediaModifier())
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 6)

                        case .appBskyEmbedGalleryView(let galleryView):
                            ContentLabelManager(
                                labels: post.labels, // Use the embedded post's labels, not parent
                                contentType: "image"
                            ) {
                                GalleryEmbedView(
                                    gallery: galleryView,
                                    shouldBlur: false // ContentLabelManager handles blurring
                                )
                                .modifier(ReadOnlyPostMediaModifier())
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 6)

                        case .appBskyEmbedExternalView(let externalView):
                            ContentLabelManager(
                                labels: post.labels, // Use the embedded post's labels, not parent
                                contentType: "link"
                            ) {
                                PostExternalEmbedContent(
                                    external: externalView.external,
                                    postID: "\(postID)-embedded"
                                )
                            }
                            .padding(.top, 6)
                            
                        case .appBskyEmbedVideoView(let videoView):
                            ContentLabelManager(
                                labels: post.labels, // Use the embedded post's labels, not parent
                                contentType: "video"
                            ) {
                                PostVideoEmbedContent(video: videoView, postID: "\(postID)-embedded-\(videoView.cid)")
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 6)
                            
                        case .unexpected:
                            EmptyView()
                        }
                    }
                    
                case .unexpected:
                    // Simple fallback for unexpected content
                    Text("This content can’t be shown")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                }
            }
        }
    }
    private var notFoundView: some View {
        HStack {
            Image(systemName: "trash")
            Text("Deleted post")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .feedEmbedCardStyle()
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    @ViewBuilder
    private func blockedView(_ blocked: AppBskyEmbedRecord.ViewBlocked) -> some View {
        BlockedContentCard(
            relationship: BlockRelationship(viewBlocked: blocked),
            authorDid: blocked.author.did.didString(),
            postUri: blocked.uri,
            variant: .embedCompact,
            path: $path
        )
    }
    
    @ViewBuilder
    private func detachedView(_ detached: AppBskyEmbedRecord.ViewDetached) -> some View {
        HStack {
            Image(systemName: "eye.slash")
            Text("Removed by author")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .feedEmbedCardStyle()
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
        .feedEmbedCardStyle()
        .onTapGesture {
            guard !isReadOnlyPreview else { return }
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
        .feedEmbedCardStyle()
        .onTapGesture {
            guard !isReadOnlyPreview else { return }
            path.append(NavigationDestination.list(list.uri))
        }
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    private var unsupportedView: some View {
        HStack {
            Image(systemName: "questionmark.circle")
            Text("This content can’t be shown")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .feedEmbedCardStyle()
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    // MARK: - Helper Methods
    
    // Note: Content label handling is now managed by ContentLabelManager
    // which provides proper user preference integration and age-based restrictions

    /// Matches the feed cell's no-avatar glyph.
    private func avatarPlaceholder(size: CGFloat) -> some View {
        Image(systemName: "person.crop.circle")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.gray)
            .frame(width: size, height: size)
    }
}

// MARK: - Embed Card Style

extension View {
    /// Shared chrome for quote, link and site cards so sibling embeds share one
    /// radius, fill and hairline.
    func feedEmbedCardStyle() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return self
            .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground))
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
            }
    }
}
