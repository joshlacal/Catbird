import SwiftUI
import Petrel
import NukeUI
import Nuke

/// A quoted record. A quoted post decides its own moderation (`decide(quotedPost:)`):
/// its `contentList` blur covers the quote body, its `contentMedia` blur gates
/// the quote's media and its author's `avatar` blur hides the avatar. The parent
/// post never adds a second gate for these causes.
struct RecordEmbedView: View {
    let record: AppBskyEmbedRecord.ViewRecordUnion
    @Binding var path: NavigationPath
    @Environment(\.postID) var postID
    @Environment(AppState.self) private var appState
    @Environment(\.isReadOnlyPostPreview) private var isReadOnlyPreview
    @Environment(\.moderationPolicy) private var moderationPolicy
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // When true, render full post styling for quoted posts (used in thread main post view)
    var useFullPostStyle: Bool = false
    /// Quotes from muted accounts stay collapsed until the viewer asks to see them.
    @State private var revealedMutedQuote: [String]?
    @State private var mutedQuoteMeasurement: MutedQuoteMeasurement?
    @State private var quoteWidth: CGFloat = 0

    private struct MutedQuoteMeasurement: Equatable {
        let identity: [String]
        let size: CGSize
        let dynamicTypeSize: DynamicTypeSize
        let fontGeneration: Int
    }

    /// A quoted record carries its own labels, which the policy reads from the
    /// record; callers pass none.
    init(
        record: AppBskyEmbedRecord.ViewRecordUnion,
        path: Binding<NavigationPath>,
        useFullPostStyle: Bool = false
    ) {
        self.record = record
        self._path = path
        self.useFullPostStyle = useFullPostStyle
    }

    var body: some View {
        switch record {
        case .appBskyEmbedRecordViewRecord(let post):
            postView(post)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { quoteWidth = $0 }
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
            let moderation = PostModerationPresentation.make(quoted: post, policy: moderationPolicy)
            ModerationContentGate(ui: moderation.body) {
                quotedPostView(post, moderation: moderation)
                    .postRevealFade(isEnabled: showsMutedQuote(post))
            }
            // A nested label warning can be shorter than the wrapping mute notice.
            // Keep that reveal from shrinking the row and clamping a feed at its end.
            .frame(minHeight: mutedQuoteMinimumHeight(post), alignment: .top)
        }
    }

    private func mutedQuoteIdentity(_ post: AppBskyEmbedRecord.ViewRecord) -> [String] {
        [appState.userDID, post.uri.uriString(), post.cid.description]
    }

    private func showsMutedQuote(_ post: AppBskyEmbedRecord.ViewRecord) -> Bool {
        revealedMutedQuote == mutedQuoteIdentity(post)
    }

    private func mutedQuoteMinimumHeight(_ post: AppBskyEmbedRecord.ViewRecord) -> CGFloat? {
        guard showsMutedQuote(post),
              let measurement = mutedQuoteMeasurement,
              measurement.identity == mutedQuoteIdentity(post),
              measurement.dynamicTypeSize == dynamicTypeSize,
              measurement.fontGeneration == appState.fontManager.generation,
              abs(measurement.size.width - quoteWidth) < 0.5
        else { return nil }
        return measurement.size.height
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
                withAnimation(PostRevealMotion.layoutAnimation(
                    reduceMotion: appState.appSettings.effectiveReduceMotion,
                    voiceOverEnabled: voiceOverEnabled
                )) {
                    revealedMutedQuote = mutedQuoteIdentity(post)
                }
            }
            .appFont(AppTextRole.subheadline)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("moderation.mutedQuote.show")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .feedEmbedCardStyle()
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: MutedQuoteMeasurement.self) { geometry in
            MutedQuoteMeasurement(
                identity: mutedQuoteIdentity(post), size: geometry.size,
                dynamicTypeSize: dynamicTypeSize, fontGeneration: appState.fontManager.generation)
        } action: { mutedQuoteMeasurement = $0 }
    }

    @ViewBuilder
    private func quotedAvatar(_ post: AppBskyEmbedRecord.ViewRecord, size: CGFloat, concealed: Bool) -> some View {
        if concealed {
            ModeratedAvatarPlaceholder(size: size)
        } else if let avatarURL = post.author.finalAvatarURL() {
            LazyImage(request: ImageLoadingManager.imageRequest(
                for: avatarURL,
                targetSize: CGSize(width: size, height: size)
            )) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    avatarPlaceholder(size: size)
                }
            }
            .pipeline(ImageLoadingManager.shared.pipeline)
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            avatarPlaceholder(size: size)
        }
    }

    @ViewBuilder
    private func quotedPostView(_ post: AppBskyEmbedRecord.ViewRecord, moderation: PostModerationPresentation) -> some View {
        Group {
            if useFullPostStyle || isReadOnlyPreview {
                // Render a fuller post style with standard card background and let tap navigate
                VStack(alignment: .leading, spacing: 8) {
                    // Author row
                    HStack(spacing: 10) {
                        quotedAvatar(post, size: 36, concealed: moderation.concealsAvatar)
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
                    ContentLabelView(causes: moderation.chips)
                    // Text
                    if case let .knownType(record) = post.value,
                       let feedPost = record as? AppBskyFeedPost,
                       !feedPost.text.isEmpty {
                        Text(feedPost.text)
                            .appFont(AppTextRole.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    // Embeds
                    embeddedContent(for: post, media: moderation.media)
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
                            quotedAvatar(post, size: 20, concealed: moderation.concealsAvatar)

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

                        ContentLabelView(causes: moderation.chips)

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
                            embeddedContent(for: post, media: moderation.media)
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

    /// Displays embedded content within a quoted post behind the quote's own
    /// `contentMedia` gate.
    ///
    /// - Parameters:
    ///   - post: The record containing embeds to display
    ///   - media: The quoted post's `ui(.contentMedia)`
    @ViewBuilder
    private func embeddedContent(for post: AppBskyEmbedRecord.ViewRecord, media: ModerationUI) -> some View {
        if let embeds = post.embeds, !embeds.isEmpty {
            ForEach(embeds.indices, id: \.self) { index in
                switch embeds[index] {
                case .appBskyEmbedImagesView(let imageView):
                    ModerationMediaGate(
                        ui: media,
                        reservedAspectRatio: ViewImageGridView.layoutAspectRatio(for: imageView.images)
                    ) {
                        ViewImageGridView(viewImages: imageView.images, shouldBlur: false)
                            .modifier(ReadOnlyPostMediaModifier())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 6)

                case .appBskyEmbedGalleryView(let galleryView):
                    ModerationMediaGate(ui: media) {
                        GalleryEmbedView(gallery: galleryView, shouldBlur: false)
                            .modifier(ReadOnlyPostMediaModifier())
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 6)

                case .appBskyEmbedExternalView(let external):
                    ModerationMediaGate(ui: media) {
                        PostExternalEmbedContent(external: external.external, postID: postID)
                    }
                    .padding(.top, 6)

                case .appBskyEmbedVideoView(let video):
                    ModerationMediaGate(ui: media) {
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
                        switch recordWithMediaView.media {
                        case .appBskyEmbedImagesView(let imagesView):
                            ModerationMediaGate(
                                ui: media,
                                reservedAspectRatio: ViewImageGridView.layoutAspectRatio(for: imagesView.images)
                            ) {
                                ViewImageGridView(viewImages: imagesView.images, shouldBlur: false)
                                    .modifier(ReadOnlyPostMediaModifier())
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 6)

                        case .appBskyEmbedGalleryView(let galleryView):
                            ModerationMediaGate(ui: media) {
                                GalleryEmbedView(gallery: galleryView, shouldBlur: false)
                                    .modifier(ReadOnlyPostMediaModifier())
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 6)

                        case .appBskyEmbedExternalView(let externalView):
                            ModerationMediaGate(ui: media) {
                                PostExternalEmbedContent(
                                    external: externalView.external,
                                    postID: "\(postID)-embedded"
                                )
                            }
                            .padding(.top, 6)

                        case .appBskyEmbedVideoView(let videoView):
                            ModerationMediaGate(ui: media) {
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
