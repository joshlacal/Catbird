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
  
  @State private var isTogglingSubscription = false
  @State private var isLiking = false
  @State private var liked = false
  @State private var likeUri: ATProtocolURI?
  @State private var didSeedViewerState = false
  @State private var showingFullDescription = false
  @State private var isDescriptionExpanded = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedDiscoveryHeaderView")
  
  private var displayedLikeCount: Int? {
    let base = feed.likeCount ?? 0
    let total = base + (liked ? 1 : 0)
    return total > 0 ? total : nil
  }
  
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      headerSection
      descriptionSection
      statsSection
      actionSection
    }
    .padding(24)
    .if(themeManager != nil) { view in
      view.themedElevatedBackground(themeManager!, appSettings: appState.appSettings)
    }
    .if(themeManager == nil) { view in
      view.background(Color(platformColor: .platformSystemBackground))
    }
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2)
    .task(id: feed.uri.uriString()) {
      seedFromFeedViewer()
    }
  }
  
  // MARK: - Header Section
  
  private var headerSection: some View {
    HStack(alignment: .top, spacing: 16) {
      feedAvatar
      
      VStack(alignment: .leading, spacing: 8) {
        feedTitleInfo
        creatorInfo
      }
      
      Spacer()
    }
  }
  
  private var feedAvatar: some View {
    AsyncImage(url: URL(string: feed.avatar?.uriString() ?? "")) { image in
      image
        .resizable()
        .scaledToFill()
    } placeholder: {
      feedPlaceholder
    }
    .frame(width: 64, height: 64)
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .overlay(
      RoundedRectangle(cornerRadius: 16)
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
        .font(.system(size: 24, weight: .bold, design: .rounded))
        .foregroundColor(.white)
    }
  }
  
  private var feedTitleInfo: some View {
    Text(feed.displayName)
      .font(.system(size: 20, weight: .bold, design: .default))
      .foregroundColor(.primary)
      .multilineTextAlignment(.leading)
  }
  
  private var creatorInfo: some View {
    Text("by @\(feed.creator.handle.description)")
      .font(.system(size: 16, weight: .medium, design: .default))
      .foregroundColor(.secondary)
      .multilineTextAlignment(.leading)
  }
  
  // MARK: - Description Section
  
  private var descriptionSection: some View {
    Group {
      if let description = feed.description, !description.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          descriptionText(description)
        }
      }
    }
  }
  
  private func descriptionText(_ description: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      let shouldTruncate = description.count > 200
      let displayText = (shouldTruncate && !isDescriptionExpanded) ? 
        String(description.prefix(200)) + "..." : description
      
      Text(displayText)
        .font(.system(size: 16, weight: .regular, design: .default))
        .foregroundColor(.primary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
      
      if shouldTruncate {
        Button(action: {
          withAnimation(.easeInOut(duration: 0.3)) {
            isDescriptionExpanded.toggle()
          }
        }) {
          Text(isDescriptionExpanded ? "Show Less" : "Show More")
            .font(.system(size: 15, weight: .medium, design: .default))
            .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
      }
    }
  }
  
  // MARK: - Stats Section
  
  private var statsSection: some View {
    Group {
      if let likeCount = displayedLikeCount {
        HStack(spacing: 6) {
          Image(systemName: "heart.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.pink)
          
          Text(formatCount(likeCount))
            .font(.system(size: 16, weight: .semibold, design: .default))
            .foregroundColor(.primary)
          
          Text("likes")
            .font(.system(size: 14, weight: .regular, design: .default))
            .foregroundColor(.secondary)
            
          Spacer()
        }
        .padding(.vertical, 8)
      }
    }
  }
  
  // MARK: - Action Section
  
  private var actionSection: some View {
    VStack(spacing: 16) {
      subscribeButton
      
      secondaryActionsMenu
    }
  }
  
  private var subscribeButton: some View {
    Button {
      Task { await toggleSubscription() }
    } label: {
      HStack(spacing: 8) {
        if isTogglingSubscription {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: .white))
            .scaleEffect(0.9)
        } else {
          if !isSubscribed {
            Image(systemName: "plus")
              .font(.system(size: 16, weight: .semibold))
          }
          Text(isSubscribed ? "Subscribed" : "Subscribe")
            .font(.system(size: 17, weight: .semibold, design: .default))
        }
      }
      .foregroundColor(isSubscribed ? .accentColor : .white)
      .frame(maxWidth: .infinity)
      .frame(height: 50)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(isSubscribed ? Color.accentColor.opacity(0.1) : Color.accentColor)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .stroke(isSubscribed ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1.5)
      )
    }
    .disabled(isTogglingSubscription)
    .buttonStyle(.plain)
  }
  
  private var secondaryActionsMenu: some View {
    Menu {
      Button(action: {
        if liked { unlikeFeed() } else { likeFeed() }
      }) {
        Label(liked ? "Unlike" : "Like", 
              systemImage: liked ? "heart.fill" : "heart")
      }
      .disabled(isLiking)
      
      Button(action: { shareFeed() }) {
        Label("Share", systemImage: "square.and.arrow.up")
      }
      
      Button(role: .destructive, action: { reportFeed() }) {
        Label("Report", systemImage: "exclamationmark.circle")
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "ellipsis")
          .font(.system(size: 16, weight: .semibold))
        Text("More")
          .font(.system(size: 17, weight: .medium, design: .default))
      }
      .foregroundColor(.secondary)
      .frame(maxWidth: .infinity)
      .frame(height: 44)
      .background(
        RoundedRectangle(cornerRadius: 12)
          .fill(Color(platformColor: .platformSecondarySystemBackground))
      )
    }
    .buttonStyle(.plain)
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
    #if os(iOS)
    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    impactFeedback.impactOccurred()
    #endif
    
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
    #if os(iOS)
    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    impactFeedback.impactOccurred()
    #endif
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
    #if os(iOS)
    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    impactFeedback.impactOccurred()
    #endif
    
    guard let url = URL(string: feed.uri.uriString()) else { return }
    
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
    #if os(iOS)
    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    impactFeedback.impactOccurred()
    #endif
    
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
