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
  let feed: AppBskyFeedDefs.GeneratorView
  let isSubscribed: Bool
  let onSubscriptionToggle: () async -> Void
  /// Invoked when the row body (avatar + text) is tapped. When `nil` the row is
  /// non-tappable — used when this view is the header of an already-open feed.
  var onTap: (() -> Void)? = nil

  @State private var isTogglingSubscription = false
  @State private var isLiking = false
  @State private var liked = false
  @State private var likeUri: ATProtocolURI?
  @State private var didSeedViewerState = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedDiscoveryHeaderView")
  
  private var displayedLikeCount: Int? {
    let base = feed.likeCount ?? 0
    let total = base + (liked ? 1 : 0)
    return total > 0 ? total : nil
  }
  
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      // Tappable content region — avatar + text. Disabled (non-tappable) when
      // no onTap is provided, e.g. the header of an already-open feed.
      Button {
        onTap?()
      } label: {
        HStack(alignment: .top, spacing: 12) {
          feedAvatar
          feedInfo
          Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(onTap == nil)

      // Trailing actions are separate hit targets, so tapping them never
      // triggers row navigation.
      subscribePill
      moreMenu
    }
    .padding(.vertical, 8)
    .task(id: feed.uri.uriString()) {
      seedFromFeedViewer()
    }
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
        .lineLimit(1)

      subtitleLine

      if let description = feed.description, !description.isEmpty {
        Text(description)
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var subtitleLine: some View {
    let handle = "by @\(feed.creator.handle.description)"
    let text = displayedLikeCount.map { "\(handle) · \(formatCount($0)) likes" } ?? handle
    return Text(text)
      .appFont(AppTextRole.subheadline)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }

  // MARK: - Trailing actions

  /// Compact subscribe / subscribed toggle. Filled accent "+" when the user is
  /// not subscribed; a tinted checkmark capsule once subscribed.
  private var subscribePill: some View {
    Button {
      Task { await toggleSubscription() }
    } label: {
      Group {
        if isTogglingSubscription {
          ProgressView()
            .controlSize(.small)
            .tint(isSubscribed ? .accentColor : .white)
        } else {
          Image(systemName: isSubscribed ? "checkmark" : "plus")
            .appFont(AppTextRole.subheadline)
            .fontWeight(.bold)
            .foregroundStyle(isSubscribed ? Color.accentColor : .white)
        }
      }
      .frame(width: 40, height: 32)
      .background(
        Capsule()
          .fill(isSubscribed ? Color.accentColor.opacity(0.12) : Color.accentColor)
      )
      .overlay(
        Capsule()
          .stroke(isSubscribed ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
      )
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .disabled(isTogglingSubscription)
    .accessibilityLabel(isSubscribed ? "Subscribed" : "Subscribe")
  }

  private var moreMenu: some View {
    Menu {
      Button {
        if liked { unlikeFeed() } else { likeFeed() }
      } label: {
        Label(liked ? "Unlike" : "Like", systemImage: liked ? "heart.fill" : "heart")
      }
      .disabled(isLiking)

      Button { shareFeed() } label: {
        Label("Share", systemImage: "square.and.arrow.up")
      }

      Button(role: .destructive) { reportFeed() } label: {
        Label("Report", systemImage: "exclamationmark.circle")
      }
    } label: {
      Image(systemName: "ellipsis")
        .appFont(AppTextRole.headline)
        .foregroundStyle(.secondary)
        .frame(width: 32, height: 32)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("More options")
  }

  
  private func toggleSubscription() async {
    guard !isTogglingSubscription else { return }
    
    isTogglingSubscription = true
    defer { isTogglingSubscription = false }
    
    await onSubscriptionToggle()
    
    // Notify state invalidation bus that feeds have changed
    await appState.stateInvalidationBus.notify(.feedListChanged)
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
        }
      } catch {
        logger.error("Like feed failed: \(error.localizedDescription)")
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
        _ = try await client.com.atproto.repo.deleteRecord(input: input)
        await MainActor.run {
          liked = false
          self.likeUri = nil
        }
      } catch {
        logger.error("Unlike feed failed: \(error.localizedDescription)")
      }
      await MainActor.run { isLiking = false }
    }
  }
  
  private func shareFeed() {
    PlatformHaptics.light()

    // Build a bsky.app web URL from the AT URI (at://did/collection/rkey)
    let creatorHandle = feed.creator.handle.description
    guard let rkey = feed.uri.recordKey,
          let url = URL(string: "https://bsky.app/profile/\(creatorHandle)/feed/\(rkey)") else { return }
    
    #if os(iOS)
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let rootViewController = windowScene.windows.first?.rootViewController else {
      return
    }
    let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let pop = vc.popoverPresentationController {
      pop.sourceView = rootViewController.view
      pop.sourceRect = CGRect(x: rootViewController.view.bounds.midX, y: rootViewController.view.bounds.midY, width: 0, height: 0)
      pop.permittedArrowDirections = []
    }
    rootViewController.present(vc, animated: true)
    #elseif os(macOS)
    NSSharingService.sharingServices(forItems: [url]).first?.perform(withItems: [url])
    #endif
  }
  
  private func reportFeed() {
    PlatformHaptics.light()
    
    Task {
      do {
        guard let client = appState.atProtoClient else { return }
        let reportInput = ComAtprotoModerationCreateReport.Input(
          reasonType: .comatprotomoderationdefsreasonspam,
          reason: "Feed reported from header",
          subject: .comAtprotoAdminDefsRepoRef(.init(
            did: try DID(didString: feed.creator.did.didString())
          ))
        )
        let (code, _) = try await client.com.atproto.moderation.createReport(input: reportInput)
        logger.info("Report result: \(code)")
      } catch {
        logger.error("Report failed: \(error.localizedDescription)")
      }
    }
  }
  
  /// Seed from inline viewer state exposed by Petrel's GeneratorView
  private func seedFromFeedViewer() {
    guard !didSeedViewerState, !liked else { return }
    if let uri = feed.viewer?.like {
      liked = true
      likeUri = uri
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
          feed: feed,
          isSubscribed: false,
          onSubscriptionToggle: {}
        )
      }
    }
  }
}
