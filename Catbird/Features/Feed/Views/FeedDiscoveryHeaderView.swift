import SwiftUI
import Petrel
import OSLog
import NukeUI

struct FeedDiscoveryHeaderView: View {
  @Environment(AppState.self) private var appState
  let feed: AppBskyFeedDefs.GeneratorView
  let isSubscribed: Bool
  let onSubscriptionToggle: () async -> Void
  
  @State private var showingDescription = false
  @State private var isTogglingSubscription = false
  @State private var previewPosts: [AppBskyFeedDefs.FeedViewPost] = []
  @State private var isLoadingPreview = false
  @State private var previewError: String?
  @State private var showFullPreview = false
  @State private var previewService: FeedPreviewService?
  
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedDiscoveryHeaderView")
  
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header Row
      HStack(alignment: .top, spacing: 12) {
        // Feed Avatar
        AsyncImage(url: URL(string: feed.avatar?.uriString() ?? "")) { image in
          image
            .resizable()
            .scaledToFill()
        } placeholder: {
          feedPlaceholder(for: feed.displayName)
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        
        // Feed Info
        VStack(alignment: .leading, spacing: 4) {
          Text(feed.displayName)
            .appFont(AppTextRole.headline)
            .foregroundColor(.primary)
          
          Text("by @\(feed.creator.handle.description)")
            .appFont(AppTextRole.subheadline)
            .foregroundColor(.secondary)
          
          HStack(spacing: 12) {
            if let likeCount = feed.likeCount {
              Label("\(formatCount(likeCount))", systemImage: "heart")
                .appFont(AppTextRole.caption)
                .foregroundColor(.secondary)
            }
            
            // Quality indicators
            if let likeCount = feed.likeCount, likeCount > 1000 {
              Text("Popular")
                .appFont(AppTextRole.caption2)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange)
                .clipShape(Capsule())
            }
          }
        }
        
        Spacer()
        
        // Subscribe Button
        Button(action: {
          Task {
            await toggleSubscription()
          }
        }) {
          HStack(spacing: 6) {
            if isTogglingSubscription {
              ProgressView()
                .scaleEffect(0.8)
            } else {
              Text(isSubscribed ? "Subscribed" : "Subscribe")
                .appFont(AppTextRole.subheadline)
                .fontWeight(.semibold)
            }
          }
          .foregroundColor(isSubscribed ? .primary : .white)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(
            RoundedRectangle(cornerRadius: 20)
              .fill(isSubscribed ? 
                    Color.gray.opacity(0.2) : 
                    Color.accentColor)
          )
        }
        .disabled(isTogglingSubscription)
      }
      
      // Description (expandable)
      if let description = feed.description {
        VStack(alignment: .leading, spacing: 8) {
          Text(description)
            .appFont(AppTextRole.subheadline)
            .foregroundColor(.secondary)
            .lineLimit(showingDescription ? nil : 2)
            .animation(.easeInOut, value: showingDescription)
          
          if description.count > 100 {
            Button(action: { showingDescription.toggle() }) {
              Text(showingDescription ? "Show less" : "Show more")
                .appFont(AppTextRole.caption)
                .foregroundColor(.accentColor)
            }
          }
        }
      }
      
      // Preview posts section - simplified and performance optimized
      if !previewPosts.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Recent posts")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
            
            Spacer()
            
            Button("See all") {
              showFullPreview = true
            }
            .appFont(AppTextRole.caption)
            .foregroundColor(.accentColor)
          }
          
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(previewPosts.prefix(3), id: \.post.uri) { feedViewPost in
                SimplifiedMiniPostCard(feedViewPost: feedViewPost)
                  .frame(width: 160, height: 60)
              }
            }
            .padding(.horizontal, 2)
          }
        }
        .padding(.top, 4)
      } else if isLoadingPreview {
        VStack(alignment: .leading, spacing: 8) {
          Text("Loading preview...")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
          
          HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
              RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 160, height: 60)
                .shimmering()
            }
          }
        }
      } else if previewError != nil {
        HStack {
          Image(systemName: "exclamationmark.triangle")
            .foregroundColor(.orange)
          Text("Preview unavailable")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
        }
        .padding(.top, 4)
      }
      
      // Action Row - simplified
      HStack(spacing: 20) {
        Button(action: { 
          let impactFeedback = UIImpactFeedbackGenerator(style: .light)
          impactFeedback.impactOccurred()
          showFullPreview = true 
        }) {
          Label("View Feed", systemImage: "eye")
            .appFont(AppTextRole.caption)
            .foregroundColor(.accentColor)
        }
        
        Button(action: { 
          let impactFeedback = UIImpactFeedbackGenerator(style: .light)
          impactFeedback.impactOccurred()
          shareFeed() 
        }) {
          Label("Share", systemImage: "square.and.arrow.up")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
        }
        
        Spacer()
      }
    }
    .padding()
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Feed: \(feed.displayName) by \(feed.creator.handle)")
    .accessibilityHint("Double tap to view feed details and preview posts")
    .task {
      await setupPreviewService()
      // Delay preview loading slightly to improve perceived performance
      try? await Task.sleep(for: .milliseconds(300))
      await loadPreviewPosts()
    }
    .sheet(isPresented: $showFullPreview) {
      FeedPreviewSheet(
        feed: feed,
        previewPosts: previewPosts,
        isSubscribed: isSubscribed,
        onSubscriptionToggle: onSubscriptionToggle
      )
    }
  }
  
  // MARK: - Helper Views
  
  @ViewBuilder
  private func feedPlaceholder(for title: String) -> some View {
    ZStack {
      LinearGradient(
        gradient: Gradient(colors: [Color.accentColor.opacity(0.7), Color.accentColor.opacity(0.5)]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      
      Text(title.prefix(1).uppercased())
        .appFont(AppTextRole.headline)
        .foregroundColor(.white)
    }
  }
  
  // MARK: - Actions
  
  private func toggleSubscription() async {
    guard !isTogglingSubscription else { return }
    
    isTogglingSubscription = true
    defer { isTogglingSubscription = false }
    
    do {
      await onSubscriptionToggle()
    } catch {
      logger.error("Failed to toggle subscription: \(error)")
    }
  }
  
  private func shareFeed() {
    guard let url = URL(string: feed.uri.uriString()) else { return }
    
    let activityVC = UIActivityViewController(
      activityItems: [url],
      applicationActivities: nil
    )
    
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let window = windowScene.windows.first {
      window.rootViewController?.present(activityVC, animated: true)
    }
  }
  
  private func reportFeed() {
    logger.info("Report feed: \(feed.uri)")
    
    Task {
      do {
        guard let client = appState.atProtoClient else {
          logger.error("No AT Protocol client available for reporting")
          return
        }
        
        // Create report for the feed generator
        let reportInput = ComAtprotoModerationCreateReport.Input(
            reasonType: .comatprotomoderationdefsreasonspam, // Default to spam, could be configurable
          reason: "Inappropriate feed content", // Could be user-provided
          subject: .comAtprotoAdminDefsRepoRef(.init(did: try DID(didString: feed.creator.did.didString())))
        )
        
        let (responseCode, _) = try await client.com.atproto.moderation.createReport(input: reportInput)
        
        if responseCode == 200 {
          logger.info("Successfully reported feed: \(feed.uri)")
          // Could show a success message to user
        } else {
          logger.error("Failed to report feed: HTTP \(responseCode)")
        }
      } catch {
        logger.error("Error reporting feed: \(error.localizedDescription)")
      }
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
  
  private func setupPreviewService() async {
    if previewService == nil {
      previewService = FeedPreviewService(appState: appState)
    }
  }
  
  private func loadPreviewPosts() async {
    guard previewPosts.isEmpty, !isLoadingPreview else { return }
    
    isLoadingPreview = true
    previewError = nil
    
    do {
      if let service = previewService {
        let posts = try await service.fetchPreview(for: feed.uri)
        await MainActor.run {
          previewPosts = posts
          isLoadingPreview = false
        }
      }
    } catch {
      logger.error("Failed to load preview posts: \(error.localizedDescription)")
      await MainActor.run {
        previewError = error.localizedDescription
        isLoadingPreview = false
      }
    }
  }
}

// MARK: - Preview

// MARK: - Mini Post Card

/// A simplified, compact post preview card for horizontal scrolling
struct SimplifiedMiniPostCard: View {
  let feedViewPost: AppBskyFeedDefs.FeedViewPost
  
  var body: some View {
    HStack(spacing: 6) {
      // Author avatar - smaller
      if let avatarUrl = feedViewPost.post.author.avatar?.uriString() {
        LazyImage(url: URL(string: avatarUrl)) { state in
          if let image = state.image {
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
          } else {
            Circle()
              .fill(Color.gray.opacity(0.3))
          }
        }
        .frame(width: 16, height: 16)
        .clipShape(Circle())
      } else {
        Circle()
          .fill(Color.gray.opacity(0.3))
          .frame(width: 16, height: 16)
      }
      
      VStack(alignment: .leading, spacing: 2) {
        // Author name - truncated
        Text(feedViewPost.post.author.displayName ?? feedViewPost.post.author.handle.description)
          .appFont(AppTextRole.caption2)
          .fontWeight(.medium)
          .foregroundColor(.primary)
          .lineLimit(1)
        
        // Post content - first line only
        if case .knownType(let record) = feedViewPost.post.record,
           let feedPost = record as? AppBskyFeedPost {
          Text(feedPost.text)
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
        }
      }
      
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color(UIColor.tertiarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Post by \(feedViewPost.post.author.displayName ?? feedViewPost.post.author.handle.description)")
  }
}

/// Original mini post card for reference - more detailed
struct MiniPostCard: View {
  let feedViewPost: AppBskyFeedDefs.FeedViewPost
  
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Author info
      HStack(spacing: 6) {
        // Author avatar
        if let avatarUrl = feedViewPost.post.author.avatar?.uriString() {
          LazyImage(url: URL(string: avatarUrl)) { state in
            if let image = state.image {
              image
                .resizable()
                .aspectRatio(contentMode: .fill)
            } else {
              Circle()
                .fill(Color.gray.opacity(0.3))
            }
          }
          .frame(width: 20, height: 20)
          .clipShape(Circle())
        } else {
          Circle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: 20, height: 20)
        }
        
        Text(feedViewPost.post.author.displayName ?? feedViewPost.post.author.handle.description)
          .appFont(AppTextRole.caption)
          .foregroundColor(.secondary)
          .lineLimit(1)
        
        Spacer()
      }
      
      // Post content
      if case .knownType(let record) = feedViewPost.post.record,
         let feedPost = record as? AppBskyFeedPost {
        Text(feedPost.text)
          .appFont(AppTextRole.body)
          .foregroundColor(.primary)
          .lineLimit(3)
          .multilineTextAlignment(.leading)
      }
      
      Spacer()
      
      // Engagement stats
      HStack(spacing: 12) {
        HStack(spacing: 2) {
          Image(systemName: "heart")
            .appFont(AppTextRole.caption2)
          Text("\(feedViewPost.post.likeCount ?? 0)")
            .appFont(AppTextRole.caption2)
        }
        
        HStack(spacing: 2) {
          Image(systemName: "arrow.2.squarepath")
            .appFont(AppTextRole.caption2)
          Text("\(feedViewPost.post.repostCount ?? 0)")
            .appFont(AppTextRole.caption2)
        }
      }
      .foregroundColor(.secondary)
    }
    .padding(8)
    .background(Color(UIColor.tertiarySystemBackground))
    .cornerRadius(8)
  }
}

// MARK: - Feed Preview Sheet

/// Full-screen feed preview with scrollable posts
struct FeedPreviewSheet: View {
  let feed: AppBskyFeedDefs.GeneratorView
  let previewPosts: [AppBskyFeedDefs.FeedViewPost]
  let isSubscribed: Bool
  let onSubscriptionToggle: () async -> Void
  
  @Environment(\.dismiss) private var dismiss
  @Environment(AppState.self) private var appState
  @State private var allPosts: [AppBskyFeedDefs.FeedViewPost] = []
  @State private var isLoading = false
  @State private var cursor: String?
  
  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(spacing: 0) {
          // Feed header
          feedHeaderView
            .padding()
          
          Divider()
          
          // Posts list
          ForEach(allPosts.isEmpty ? previewPosts : allPosts, id: \.post.uri) { feedViewPost in
            VStack(spacing: 0) {
              PreviewPostRow(feedViewPost: feedViewPost)
                .padding()
                .onAppear {
                  // Load more when near the end
                  if feedViewPost == (allPosts.isEmpty ? previewPosts : allPosts).last {
                    Task {
                      await loadMorePosts()
                    }
                  }
                }
              
              Divider()
            }
          }
          
          // Load more indicator
          if isLoading {
            ProgressView("Loading more posts...")
              .padding()
          }
          
          // End of posts indicator
          if !isLoading && !(allPosts.isEmpty ? previewPosts : allPosts).isEmpty {
            Text("No more posts")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
              .padding()
          }
        }
      }
      .refreshable {
        // Pull to refresh
        await refreshFeed()
      }
      .navigationTitle("Feed Preview")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Close") {
            dismiss()
          }
        }
        
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: {
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            Task {
              await onSubscriptionToggle()
            }
          }) {
            Text(isSubscribed ? "Unsubscribe" : "Subscribe")
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .tint(isSubscribed ? .gray : .accentColor)
          .accessibilityLabel(isSubscribed ? "Unsubscribe from feed" : "Subscribe to feed")
        }
      }
    }
    .task {
      if allPosts.isEmpty {
        allPosts = previewPosts
        await loadMorePosts()
      }
    }
  }
  
  private var feedHeaderView: some View {
    VStack(alignment: .center, spacing: 12) {
      // Avatar
      AsyncImage(url: URL(string: feed.avatar?.uriString() ?? "")) { image in
        image
          .resizable()
          .scaledToFill()
      } placeholder: {
        feedAvatarPlaceholder
      }
      .frame(width: 80, height: 80)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      
      // Feed info
      VStack(spacing: 4) {
        Text(feed.displayName)
          .appFont(AppTextRole.title2)
          .fontWeight(.bold)
        
        Text("by @\(feed.creator.handle.description)")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.secondary)
      }
      
      // Description
      if let description = feed.description, !description.isEmpty {
        Text(description)
          .appFont(AppTextRole.body)
          .foregroundColor(.primary)
          .multilineTextAlignment(.center)
          .padding(.horizontal)
      }
      
      // Stats
      HStack(spacing: 24) {
        if let likeCount = feed.likeCount {
          VStack {
            Text(formatCount(likeCount))
              .appFont(AppTextRole.headline)
            Text("Likes")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
          }
        }
        
        VStack {
          Text(formatCount(allPosts.count))
            .appFont(AppTextRole.headline)
          Text("Posts shown")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
        }
      }
    }
  }
  
  private var feedAvatarPlaceholder: some View {
    ZStack {
      LinearGradient(
        gradient: Gradient(colors: [
          Color.accentColor.opacity(0.7),
          Color.accentColor.opacity(0.5)
        ]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      
      Text(feed.displayName.prefix(1).uppercased())
        .appFont(AppTextRole.title1)
        .foregroundColor(.white)
    }
  }
  
  private func refreshFeed() async {
    cursor = nil
    allPosts = []
    await loadMorePosts()
  }
  
  private func loadMorePosts() async {
    guard !isLoading, cursor != nil || allPosts.isEmpty else { return }
    isLoading = true
    
    do {
      guard let client = appState.atProtoClient else { 
        await MainActor.run { isLoading = false }
        return 
      }
      
      let params = AppBskyFeedGetFeed.Parameters(
        feed: feed.uri,
        limit: 20,
        cursor: cursor
      )
      
      let (responseCode, response) = try await client.app.bsky.feed.getFeed(input: params)
      
      if responseCode == 200, let feedResponse = response {
        await MainActor.run {
          if cursor == nil {
            // First load or refresh
            allPosts = feedResponse.feed
          } else {
            // Append more posts
            allPosts.append(contentsOf: feedResponse.feed)
          }
          cursor = feedResponse.cursor
          isLoading = false
        }
      } else {
        await MainActor.run { isLoading = false }
      }
    } catch {
      await MainActor.run { isLoading = false }
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

// MARK: - Preview Post Row

/// Simplified post row for feed preview
struct PreviewPostRow: View {
  let feedViewPost: AppBskyFeedDefs.FeedViewPost
  
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      // Author avatar
      if let avatarUrl = feedViewPost.post.author.avatar?.uriString() {
        LazyImage(url: URL(string: avatarUrl)) { state in
          if let image = state.image {
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
          } else {
            Circle()
              .fill(Color.gray.opacity(0.3))
          }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
      } else {
        Circle()
          .fill(Color.gray.opacity(0.3))
          .frame(width: 40, height: 40)
      }
      
      VStack(alignment: .leading, spacing: 4) {
        // Author info
        HStack {
          Text(feedViewPost.post.author.displayName ?? feedViewPost.post.author.handle.description)
            .appFont(AppTextRole.subheadline)
            .fontWeight(.medium)
          
          Text("@\(feedViewPost.post.author.handle.description)")
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
          
          Spacer()
        }
        
        // Post content
        if case .knownType(let record) = feedViewPost.post.record,
           let feedPost = record as? AppBskyFeedPost {
          Text(feedPost.text)
            .appFont(AppTextRole.body)
            .foregroundColor(.primary)
            .multilineTextAlignment(.leading)
        }
        
        // Media preview indicator
        if feedViewPost.post.embed != nil {
          HStack {
            Image(systemName: "photo")
              .foregroundColor(.secondary)
            Text("Media attached")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
          }
          .padding(.top, 2)
        }
        
        // Engagement stats
        HStack(spacing: 16) {
          HStack(spacing: 2) {
            Image(systemName: "heart")
              .appFont(AppTextRole.caption)
            Text("\(feedViewPost.post.likeCount ?? 0)")
              .appFont(AppTextRole.caption)
          }
          
          HStack(spacing: 2) {
            Image(systemName: "arrow.2.squarepath")
              .appFont(AppTextRole.caption)
            Text("\(feedViewPost.post.repostCount ?? 0)")
              .appFont(AppTextRole.caption)
          }
          
          HStack(spacing: 2) {
            Image(systemName: "bubble.left")
              .appFont(AppTextRole.caption)
            Text("\(feedViewPost.post.replyCount ?? 0)")
              .appFont(AppTextRole.caption)
          }
        }
        .foregroundColor(.secondary)
        .padding(.top, 4)
      }
    }
  }
}

// MARK: - Shimmer Effect
// Note: shimmering() extension is defined elsewhere in the codebase

// MARK: - Preview

#Preview {
  let sampleFeed = AppBskyFeedDefs.GeneratorView(
    uri: try! ATProtocolURI(uriString: "at://did:plc:sample/app.bsky.feed.generator/sample"),
    cid: try! CID.parse("bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi"),
    did: try! DID(didString: "did:plc:sample"),
    creator: AppBskyActorDefs.ProfileView(
        did: try! DID(didString: "did:plc:sample"),
        handle: try! Handle(handleString: "creator.bsky.social"),
      displayName: "Feed Creator",
      description: nil,
      avatar: nil,
      associated: nil,
      indexedAt: nil,
      createdAt: try! ATProtocolDate(date: Date()),
      viewer: nil,
      labels: [],
      verification: nil,
      status: nil
    ),
    displayName: "Sample Feed",
    description: "This is a sample feed for testing the header view component.",
    descriptionFacets: nil,
    avatar: nil,
    likeCount: 1250,
    acceptsInteractions: true,
    labels: [],
    viewer: nil,
    contentMode: nil,
    indexedAt: try! ATProtocolDate(date: Date())
  )
  
  FeedDiscoveryHeaderView(
    feed: sampleFeed,
    isSubscribed: false,
    onSubscriptionToggle: {}
  )
  .padding()
}
