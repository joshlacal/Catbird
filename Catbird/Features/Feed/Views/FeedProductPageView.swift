import OSLog
import Petrel
import SwiftUI

/// App Store-style Product Page for an ATProto feed generator:
/// Header (crisp icon, title, tappable creator, instant +Add & Open actions),
/// horizontally scrollable Metadata Strip (Likes, Velocity, Creator, Category),
/// Live Posts rendered as interactive "Screenshots" (horizontal card carousel or vertical list),
/// and full description.
struct FeedProductPageView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  let feed: AppBskyFeedDefs.GeneratorView
  let preview: FeedDiscoveryPreviewModel
  @Binding var path: NavigationPath
  let onOpen: (AppBskyFeedDefs.GeneratorView) -> Void

  @State private var retryGeneration = 0
  @State private var previewStyle: PreviewDisplayStyle = .carousel
  @State private var isLiking = false
  @State private var liked = false
  @State private var likeURI: ATProtocolURI?
  @State private var didSeedViewerLike = false
  @State private var countIncludesViewerLike = false
  @State private var isShowingReportSheet = false

  private let logger = Logger(subsystem: "blue.catbird", category: "FeedProductPageView")

  private enum PreviewDisplayStyle: String, CaseIterable, Identifiable {
    case carousel
    case list
    var id: String { rawValue }
  }

  private var displayedLikeCount: Int {
    let base = max(0, (feed.likeCount ?? 0) - (countIncludesViewerLike ? 1 : 0))
    return base + (liked ? 1 : 0)
  }

  private var category: FeedDiscoveryCategory? {
    FeedDiscoveryCategoryClassifier.primaryCategory(for: feed)
  }

  private var shareURL: URL? {
    guard let rkey = feed.uri.recordKey else { return nil }
    return URL(string: "https://bsky.app/profile/\(feed.creator.handle.description)/feed/\(rkey)")
  }

  private var isPreviewForThisFeed: Bool {
    preview.selectedFeedURI == feed.id
  }

  private var velocityEstimate: FeedVelocityEstimate? {
    guard isPreviewForThisFeed else { return nil }
    switch preview.state {
    case .loaded:
      return FeedVelocityEstimator.estimate(from: preview.posts)
    case .empty, .filtered:
      return .empty
    case .idle, .loading, .failed:
      return nil
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        headerSection
          .padding(.horizontal, 16)
          .padding(.top, 12)

        FeedProductMetadataStrip(
          feed: feed,
          displayedLikeCount: displayedLikeCount,
          liked: liked,
          velocityEstimate: velocityEstimate,
          category: category
        )

        livePreviewSection

        aboutSection
          .padding(.horizontal, 16)
      }
      .padding(.bottom, 32)
      .frame(maxWidth: 760)
      .frame(maxWidth: .infinity)
    }
    .background(Color(platformColor: .platformSystemBackground))
    .navigationTitle(feed.displayName)
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar { ToolbarItem(placement: .primaryAction) { moreMenu } }
    .accessibilityIdentifier("feed.product.page.\(feed.id)")
    .task(id: PreviewLoadKey(feedID: feed.id, retry: retryGeneration)) {
      seedViewerLike()
      await preview.load(feed: feed, forceRefresh: retryGeneration > 0)
    }
    .sheet(isPresented: $isShowingReportSheet) {
      if let client = appState.atProtoClient {
        let reportingService = ReportingService(client: client)
        let subject = reportingService.createFeedSubject(uri: feed.uri, cid: feed.cid)
        ReportFormView(
          reportingService: reportingService,
          subject: subject,
          contentDescription: String(
            localized: "Feed: \(feed.displayName)",
            comment: "Report sheet target description for a custom feed — variable is the feed display name"
          )
        )
      }
    }
  }

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 14) {
        StorefrontFeedIcon(feed: feed, size: 60)
        VStack(alignment: .leading, spacing: 4) {
          Text(feed.displayName)
            .appFont(AppTextRole.title3)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
          NavigationLink(value: NavigationDestination.profile(feed.creator.did.didString())) {
            HStack(spacing: 4) {
              Text(verbatim: "@\(feed.creator.handle.description)")
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
              Image(systemName: "chevron.forward")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor.opacity(0.75))
            }
          }
          .buttonStyle(.plain)
          .accessibilityLabel("View creator @\(feed.creator.handle.description)")
          .accessibilityIdentifier("feed.product.creatorLink")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      let actionLayout = dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
      actionLayout {
        FeedLibraryControls(feed: feed, onOpen: { onOpen(feed) }, minimumLabelHeight: 32, statusChip: true)
          .buttonBorderShape(.capsule)
          .id(feed.id)
        Button { onOpen(feed) } label: {
          Label("Open Feed", systemImage: "arrow.up.forward")
            .font(.subheadline.weight(.semibold))
            .frame(minHeight: 36)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .accessibilityIdentifier("feed.discovery.open")
        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
        Button { if liked { unlikeFeed() } else { likeFeed() } } label: {
          Image(systemName: liked ? "heart.fill" : "heart")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(liked ? .pink : .secondary)
            .frame(width: 40, height: 40)
            .background(Color.secondary.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(isLiking)
        .accessibilityLabel(liked ? "Unlike feed" : "Like feed")
        .accessibilityIdentifier("feed.product.like")
      }
    }
  }

  private var livePreviewSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 8) {
        Text("Live Preview")
          .appFont(AppTextRole.title3)
          .fontWeight(.bold)
          .accessibilityAddTraits(.isHeader)

        Spacer()

        Picker("Preview Layout", selection: $previewStyle) {
          Image(systemName: "rectangle.grid.1x2").tag(PreviewDisplayStyle.carousel)
            .accessibilityLabel("Cards")
          Image(systemName: "list.bullet").tag(PreviewDisplayStyle.list)
            .accessibilityLabel("List")
        }
        .pickerStyle(.segmented)
        .frame(width: 84)

        Button("Refresh preview", systemImage: "arrow.clockwise") {
          retryGeneration += 1
        }
        .labelStyle(.iconOnly)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(width: 32, height: 32)
      }
      .padding(.horizontal, 16)

      previewBody
    }
    .accessibilityIdentifier("feed.product.livePreview")
  }

  private struct PreviewLoadKey: Hashable {
    let feedID: String
    let retry: Int
  }
}

extension FeedProductPageView {
  @ViewBuilder
  private var previewBody: some View {
    if !isPreviewForThisFeed {
      loadingPreviewPlaceholder
    } else {
      switch preview.state {
      case .idle, .loading:
        loadingPreviewPlaceholder
      case .empty:
        ContentUnavailableView(
          "No recent posts",
          systemImage: "text.bubble",
          description: Text("Try another feed or check back later.")
        )
        .padding(.horizontal, 16)
      case .filtered:
        ContentUnavailableView(
          "No posts to preview",
          systemImage: "eye.slash",
          description: Text("Your moderation and content settings hide the available posts.")
        )
        .padding(.horizontal, 16)
      case .failed(let message):
        FeedDiscoveryRetryView(message: message) { retryGeneration += 1 }
          .padding(.horizontal, 16)
      case .loaded:
        switch previewStyle {
        case .carousel:
          screenshotCardCarousel(posts: Array(preview.posts.prefix(5)))
        case .list:
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(preview.posts, id: \.id) { post in
              VStack(spacing: 0) {
                EnhancedFeedPost(feedViewPost: post, path: $path, isReadOnly: true)
                  .padding(.horizontal, 8)
                Divider()
              }
            }
          }
        }
      }
    }
  }

  private var loadingPreviewPlaceholder: some View {
    HStack {
      Spacer()
      ProgressView("Loading live posts…").padding(.vertical, 36)
      Spacer()
    }
  }

  private func screenshotCardCarousel(posts: [AppBskyFeedDefs.FeedViewPost]) -> some View {
    ScrollView(.horizontal) {
      LazyHStack(alignment: .top, spacing: 12) {
        ForEach(posts, id: \.id) { post in
          FeedPreviewScreenshotCard(post: post) {
            path.append(NavigationDestination.post(post.post.uri))
          }
          .containerRelativeFrame(.horizontal) { width, _ in min(max(width - 52, 260), 336) }
        }
      }
      .scrollTargetLayout()
      .padding(.horizontal, 16)
    }
    .scrollIndicators(.hidden)
    .scrollTargetBehavior(.viewAligned)
  }

  private var aboutSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("About This Feed")
        .appFont(AppTextRole.headline)
        .fontWeight(.bold)
        .accessibilityAddTraits(.isHeader)
      if let description = feed.description?.trimmingCharacters(in: .whitespacesAndNewlines),
         !description.isEmpty {
        Text(description)
          .appFont(AppTextRole.body)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("This feed has no description.")
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.top, 4)
  }

  private var moreMenu: some View {
    Menu {
      Button {
        if liked { unlikeFeed() } else { likeFeed() }
      } label: {
        Label(liked ? "Unlike Feed" : "Like Feed", systemImage: liked ? "heart.fill" : "heart")
      }
      .disabled(isLiking)
      if let shareURL {
        ShareLink(item: shareURL) { Label("Share Feed", systemImage: "square.and.arrow.up") }
      }
      Button(role: .destructive) {
        PlatformHaptics.light()
        isShowingReportSheet = true
      } label: {
        Label("Report Feed", systemImage: "exclamationmark.circle")
      }
    } label: {
      Image(systemName: "ellipsis.circle").accessibilityLabel("More options")
    }
  }

  private func seedViewerLike() {
    guard !didSeedViewerLike else { return }
    if let uri = feed.viewer?.like {
      liked = true
      likeURI = uri
      countIncludesViewerLike = true
    }
    didSeedViewerLike = true
  }

  private func likeFeed() {
    guard !isLiking, !liked else { return }
    PlatformHaptics.light()
    Task { @MainActor in
      isLiking = true
      defer { isLiking = false }
      do {
        guard let client = appState.atProtoClient else { return }
        let record = AppBskyFeedLike(
          subject: ComAtprotoRepoStrongRef(uri: feed.uri, cid: feed.cid),
          createdAt: ATProtocolDate(date: Date()),
          via: nil
        )
        let did = try await client.getDid()
        let input = ComAtprotoRepoCreateRecord.Input(
          repo: try ATIdentifier(string: did),
          collection: try NSID(nsidString: "app.bsky.feed.like"),
          record: .knownType(record)
        )
        let (code, data) = try await client.com.atproto.repo.createRecord(input: input)
        if code == 200 {
          liked = true
          likeURI = data?.uri
        } else {
          appState.toastManager.show(ToastItem(
            message: String(localized: "Couldn’t like this feed. Try again.", comment: "Error toast when liking a feed fails"),
            icon: "exclamationmark.triangle.fill"
          ))
        }
      } catch {
        logger.error("Product page like failed: \(error.localizedDescription)")
        if let message = UserFacingError.message(for: error, action: "like this feed") {
          appState.toastManager.show(ToastItem(message: message, icon: "exclamationmark.triangle.fill"))
        }
      }
    }
  }

  private func unlikeFeed() {
    guard !isLiking, liked else { return }
    PlatformHaptics.light()
    Task { @MainActor in
      isLiking = true
      defer { isLiking = false }
      do {
        guard let client = appState.atProtoClient, let likeURI, let rkey = likeURI.recordKey else { return }
        let did = try await client.getDid()
        let input = ComAtprotoRepoDeleteRecord.Input(
          repo: try ATIdentifier(string: did),
          collection: try NSID(nsidString: "app.bsky.feed.like"),
          rkey: try RecordKey(keyString: rkey)
        )
        let code = try await client.com.atproto.repo.deleteRecord(input: input).responseCode
        if code == 200 {
          liked = false
          self.likeURI = nil
        }
      } catch {
        logger.error("Product page unlike failed: \(error.localizedDescription)")
        if let message = UserFacingError.message(for: error, action: "remove your like") {
          appState.toastManager.show(ToastItem(message: message, icon: "exclamationmark.triangle.fill"))
        }
      }
    }
  }
}
