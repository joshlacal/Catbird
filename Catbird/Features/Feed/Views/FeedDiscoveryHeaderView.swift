import SwiftUI
import Petrel
import OSLog
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct FeedDiscoveryHeaderView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.themeManager) private var themeManager
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let feed: AppBskyFeedDefs.GeneratorView
  var libraryControlsTrailing = false
  /// Invoked when the row body (avatar + text) is tapped. When `nil` the row is
  /// non-tappable — used when this view is the header of an already-open feed.
  var onTap: (() -> Void)? = nil
  var onLikedByTap: (() -> Void)? = nil
  var onAskCatbird: (() -> Void)? = nil
  var onReportTap: (() -> Void)? = nil
  var onOpenFeed: (() -> Void)? = nil
  @State private var isLiking = false
  @State private var liked = false
  @State private var likeUri: ATProtocolURI?
  @State private var didSeedViewerState = false
  /// The server's like count already includes a like the viewer made earlier.
  @State private var countIncludesViewerLike = false
  @State private var isShowingReportSheet = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedDiscoveryHeaderView")
  
  private var displayedLikeCount: Int? {
    let base = max(0, (feed.likeCount ?? 0) - (countIncludesViewerLike ? 1 : 0))
    let total = base + (liked ? 1 : 0)
    return total > 0 ? total : nil
  }
  
  var body: some View {
    Group {
      if libraryControlsTrailing {
        HStack(alignment: .top, spacing: 12) {
          previewButton
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
          VStack(alignment: .trailing, spacing: 4) {
            FeedLibraryControls(feed: feed, onOpen: onOpenFeed,
                                compactLabels: dynamicTypeSize.isAccessibilitySize,
                                alignsTrailing: true)
            moreMenu
          }
          .frame(width: dynamicTypeSize.isAccessibilitySize ? 76 : 104, alignment: .trailing)
          .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          previewButton
          HStack(alignment: .top) {
            FeedLibraryControls(feed: feed, onOpen: onOpenFeed)
            Spacer(minLength: 8)
            moreMenu
          }
        }
      }
    }
    .padding(.vertical, 8)
    .sheet(isPresented: $isShowingReportSheet) {
      if let client = appState.atProtoClient {
        let reportingService = ReportingService(client: client)
        let subject = reportingService.createFeedSubject(uri: feed.uri, cid: feed.cid)
        ReportFormView(
          reportingService: reportingService,
          subject: subject,
          contentDescription: "Feed: \(feed.displayName)"
        )
      }
    }
    .task(id: feed.uri.uriString()) {
      seedFromFeedViewer()
    }
  }

  /// Preview and library controls stay separate buttons in both arrangements.
  private var previewButton: some View {
    Button {
      onTap?()
    } label: {
      Group {
        if libraryControlsTrailing && dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 8) {
            feedAvatar
            feedInfo
          }
        } else {
          HStack(alignment: .top, spacing: 12) {
            feedAvatar
            feedInfo
            if !libraryControlsTrailing { Spacer(minLength: 8) }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(onTap == nil)
    .accessibilityIdentifier("feed.discovery.preview.\(feed.uri.uriString())")
  }
  // MARK: - Avatar

  private var feedAvatar: some View {
    AsyncImage(url: URL(string: feed.avatar?.uriString() ?? "")) { image in
      image
        .resizable()
        .scaledToFill()
    } placeholder: {
      feedPlaceholder
    }
    .frame(width: 52, height: 52)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .stroke(Color(platformColor: PlatformColor.platformSeparator).opacity(0.15), lineWidth: 1)
    )
  }

  private var feedPlaceholder: some View {
    ZStack {
      LinearGradient(
        colors: [Color.accentColor.opacity(0.8), Color.accentColor.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      Text(feed.displayName.prefix(1).uppercased())
        .font(.system(size: 22, weight: .bold, design: .rounded))
        .foregroundColor(.white)
    }
  }

  // MARK: - Info

  private var feedInfo: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(feed.displayName)
        .appFont(AppTextRole.headline)
        .foregroundStyle(.primary)
        .lineLimit(libraryControlsTrailing ? nil : 1)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)

      subtitleLine

      if let description = feed.description, !description.isEmpty {
        Text(description)
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(nil)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var subtitleLine: some View {
    let handle = "by @\(feed.creator.handle.description)"
    let text = displayedLikeCount.map { "\(handle) · \(formatCount($0)) likes" } ?? handle
    return Text(text)
      .appFont(AppTextRole.subheadline)
      .foregroundStyle(.secondary)
      .lineLimit(libraryControlsTrailing ? nil : 1)
      .multilineTextAlignment(.leading)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - Trailing actions

  private var moreMenu: some View {
    Menu {
      if let onAskCatbird {
        Button {
          onAskCatbird()
        } label: {
          Label("Ask Catbird", systemImage: "sparkles")
        }
      }

      Button {
        if liked { unlikeFeed() } else { likeFeed() }
      } label: {
        Label(liked ? "Unlike" : "Like", systemImage: liked ? "heart.fill" : "heart")
      }
      .disabled(isLiking)
      if let onLikedByTap {
        Button {
          onLikedByTap()
        } label: {
          Label("Liked By", systemImage: "heart")
        }
      }


      if let shareURL {
        ShareLink(item: shareURL) {
          Label("Share", systemImage: "square.and.arrow.up")
        }
      }

      Button(role: .destructive) {
        PlatformHaptics.light()
        if let onReportTap {
          onReportTap()
        } else {
          isShowingReportSheet = true
        }
      } label: {
        Label("Report", systemImage: "exclamationmark.circle")
      }
    } label: {
      Image(systemName: "ellipsis")
        .appFont(AppTextRole.headline)
        .foregroundStyle(.secondary)
        .frame(width: libraryControlsTrailing ? 44 : 32,
               height: libraryControlsTrailing ? 44 : 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("More options")
  }

  
  // MARK: - Share / Report
  
  private func likeFeed() {
    guard !isLiking, !liked else { return }
    PlatformHaptics.light()
    
    Task {
      do {
        await MainActor.run { isLiking = true }
        guard let client = appState.atProtoClient else { return }
        let postRef = ComAtprotoRepoStrongRef(
          uri: feed.uri,
          cid: feed.cid
        )
        let likeRecord = AppBskyFeedLike(
          subject: postRef,
          createdAt: ATProtocolDate(date: Date()),
          via: nil
        )
        let did = try await client.getDid()
        let input = ComAtprotoRepoCreateRecord.Input(
          repo: try ATIdentifier(string: did),
          collection: try NSID(nsidString: "app.bsky.feed.like"),
          record: .knownType(likeRecord)
        )
        let (code, data) = try await client.com.atproto.repo.createRecord(input: input)
        logger.info("Like feed result: \(code)")
        if code == 200 {
          await MainActor.run {
            liked = true
            if let data {
              likeUri = data.uri
            }
          }
        } else {
          showFailureToast("Couldn’t like this feed. Try again.")
        }
      } catch {
        logger.error("Like feed failed: \(error.localizedDescription)")
        if let message = UserFacingError.message(for: error, action: "like this feed") {
          showFailureToast(message)
        }
      }
      await MainActor.run {
        isLiking = false
      }
    }
  }

  private func unlikeFeed() {
    guard !isLiking, liked else { return }
    PlatformHaptics.light()
    Task {
      do {
        await MainActor.run { isLiking = true }
        guard let client = appState.atProtoClient else { return }
        guard let likeUri = likeUri, let rkey = likeUri.recordKey else {
          await MainActor.run { isLiking = false }
          return
        }
        let did = try await client.getDid()
        let input = ComAtprotoRepoDeleteRecord.Input(
          repo: try ATIdentifier(string: did),
          collection: try NSID(nsidString: "app.bsky.feed.like"),
          rkey: try RecordKey(keyString: rkey)
        )
        let responseCode = try await client.com.atproto.repo.deleteRecord(input: input).responseCode
        if responseCode == 200 {
          await MainActor.run {
            liked = false
            self.likeUri = nil
          }
        } else {
          logger.error("Unlike feed returned status \(responseCode)")
          showFailureToast("Couldn’t remove your like. Try again.")
        }
      } catch {
        logger.error("Unlike feed failed: \(error.localizedDescription)")
        if let message = UserFacingError.message(for: error, action: "remove your like") {
          showFailureToast(message)
        }
      }
      await MainActor.run { isLiking = false }
    }
  }
  
  /// The feed's bsky.app web link, built from its AT URI (at://did/collection/rkey).
  private var shareURL: URL? {
    guard let rkey = feed.uri.recordKey else { return nil }
    return URL(string: "https://bsky.app/profile/\(feed.creator.handle.description)/feed/\(rkey)")
  }

  private func showFailureToast(_ message: String) {
    appState.toastManager.show(ToastItem(message: message, icon: "exclamationmark.triangle.fill"))
  }
  
  /// Seed from inline viewer state exposed by Petrel's GeneratorView
  private func seedFromFeedViewer() {
    guard !didSeedViewerState, !liked else { return }
    if let uri = feed.viewer?.like {
      liked = true
      likeUri = uri
      countIncludesViewerLike = true
    }
    didSeedViewerState = true
  }
  
  // MARK: - Seed initial like state from server (if available)
  private func seedViewerLikeState() async {
    guard !didSeedViewerState, !liked else { return }
    do {
      guard let client = appState.atProtoClient else { return }
      let response = try await client.app.bsky.feed.getFeedGenerator(input: .init(feed: feed.uri)).data
      if let view = response?.view, let viewer = view.viewer, let uri = viewer.like {
        await MainActor.run {
          self.liked = true
          self.likeUri = uri
          self.countIncludesViewerLike = true
          self.didSeedViewerState = true
        }
      } else {
        await MainActor.run { self.didSeedViewerState = true }
      }
    } catch {
      // Non-fatal; leave as not seeded to try again on future reloads
    }
  }
  private func formatCount(_ count: Int) -> String {
    if count >= 1000000 {
      return String(format: "%.1fM", Double(count) / 1000000)
    } else if count >= 1000 {
      return String(format: "%.1fK", Double(count) / 1000)
    } else {
      return "\(count)"
    }
  }
}

#Preview("Feed Discovery Header") {
  AsyncPreviewDataContent { appState in
    await PreviewData.popularFeeds(from: appState).first
  } content: { appState, feed in
    NavigationStack {
      ScrollView {
        FeedDiscoveryHeaderView(
          feed: feed
        )
      }
    }
  }
}
