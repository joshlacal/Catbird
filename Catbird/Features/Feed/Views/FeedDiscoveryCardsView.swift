import SwiftUI
import Petrel
import OSLog
import NukeUI

// MARK: - Swipeable Feed Discovery Cards View

struct FeedDiscoveryCardsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  @State private var feeds: [AppBskyFeedDefs.GeneratorView] = []
  @State private var currentIndex = 0
  @State private var isLoading = true
  @State private var loadingError: String?
  @State private var dragOffset: CGSize = .zero
  @State private var subscriptionStatus: [String: Bool] = [:]
  @State private var showOnboarding = true
  @State private var hasInteracted = false
  
  private let logger = Logger(subsystem: "blue.catbird", category: "FeedDiscoveryCards")
  private let cardAnimationDuration = 0.25
  private let swipeThreshold: CGFloat = 100
  
  var body: some View {
    NavigationStack {
      ZStack {
        // Background
        Color(.systemBackground)
          .ignoresSafeArea()
        
        if isLoading {
          loadingView
        } else if let error = loadingError {
          errorView(error)
        } else if feeds.isEmpty {
          emptyStateView
        } else {
          // Card stack
          cardStackView
        }
        
        // Onboarding overlay
        if showOnboarding && !hasInteracted {
          onboardingOverlay
        }
      }
      .navigationTitle("Discover Feeds")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Close") {
            dismiss()
          }
        }
        
        ToolbarItem(placement: .navigationBarTrailing) {
          Button("Help") {
            showOnboarding = true
          }
        }
      }
      .onAppear {
        loadFeeds()
      }
    }
  }
  
  // MARK: - Card Stack View
  
  private var cardStackView: some View {
    GeometryReader { geometry in
      ZStack {
        // Background cards (next 2 cards for depth)
        ForEach(nextCardIndices, id: \.self) { index in
          if index < feeds.count {
            FeedDiscoveryCard(
              feed: feeds[index],
              isSubscribed: subscriptionStatus[feeds[index].uri.uriString()] ?? false,
              onSubscriptionToggle: {
                await toggleSubscription(feeds[index])
              }
            )
            .scaleEffect(scaleForCard(at: index))
            .offset(y: offsetForCard(at: index))
            .zIndex(Double(feeds.count - index))
            .allowsHitTesting(false)
          }
        }
        
        // Current active card
        if currentIndex < feeds.count {
          FeedDiscoveryCard(
            feed: feeds[currentIndex],
            isSubscribed: subscriptionStatus[feeds[currentIndex].uri.uriString()] ?? false,
            onSubscriptionToggle: {
              await toggleSubscription(feeds[currentIndex])
            }
          )
          .offset(dragOffset)
          .rotationEffect(.degrees(Double(dragOffset.width) * 0.1))
          .scaleEffect(1.0 - abs(dragOffset.width) * 0.001)
          .zIndex(Double(feeds.count))
          .gesture(
            DragGesture()
              .onChanged { value in
                dragOffset = value.translation
                if !hasInteracted {
                  hasInteracted = true
                  withAnimation(.easeOut(duration: 0.3)) {
                    showOnboarding = false
                  }
                }
              }
              .onEnded { value in
                handleSwipeGesture(value)
              }
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  
  // MARK: - Helper Views
  
  private var loadingView: some View {
    VStack(spacing: 20) {
      ProgressView()
        .scaleEffect(1.5)
      Text("Loading feeds...")
        .appFont(AppTextRole.headline)
        .foregroundColor(.secondary)
    }
  }
  
  private func errorView(_ error: String) -> some View {
    VStack(spacing: 20) {
      Image(systemName: "exclamationmark.triangle")
        .appFont(AppTextRole.largeTitle)
        .foregroundColor(.red)
      
      Text("Failed to load feeds")
        .appFont(AppTextRole.headline)
      
      Text(error)
        .appFont(AppTextRole.body)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
      
      Button("Try Again") {
        loadFeeds()
      }
      .buttonStyle(.borderedProminent)
    }
    .padding()
  }
  
  private var emptyStateView: some View {
    VStack(spacing: 20) {
      Image(systemName: "rectangle.stack")
        .appFont(AppTextRole.largeTitle)
        .foregroundColor(.secondary)
      
      Text("No feeds available")
        .appFont(AppTextRole.headline)
      
      Text("Check back later for new feed recommendations")
        .appFont(AppTextRole.body)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
    }
    .padding()
  }
  
  private var onboardingOverlay: some View {
    ZStack {
      // Semi-transparent background
      Color.black.opacity(0.7)
        .ignoresSafeArea()
      
      VStack(spacing: 24) {
        VStack(spacing: 16) {
          Text("Discover New Feeds")
            .appFont(AppTextRole.title1)
            .fontWeight(.bold)
            .foregroundColor(.white)
          
          Text("Swipe through feed previews to find content you love")
            .appFont(AppTextRole.body)
            .foregroundColor(.white.opacity(0.9))
            .multilineTextAlignment(.center)
        }
        
        VStack(spacing: 20) {
          onboardingGestureHint(
            icon: "arrow.up",
            text: "Swipe up for next feed",
            color: .blue
          )
          
          onboardingGestureHint(
            icon: "arrow.right",
            text: "Swipe right to subscribe",
            color: .green
          )
          
          onboardingGestureHint(
            icon: "arrow.left",
            text: "Swipe left to skip",
            color: .orange
          )
        }
        
        Button("Got it!") {
          withAnimation(.easeOut(duration: 0.3)) {
            showOnboarding = false
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.white)
        .foregroundColor(.black)
      }
      .padding(32)
    }
    .onTapGesture {
      withAnimation(.easeOut(duration: 0.3)) {
        showOnboarding = false
      }
    }
  }
  
  private func onboardingGestureHint(icon: String, text: String, color: Color) -> some View {
    HStack(spacing: 16) {
      Image(systemName: icon)
        .appFont(AppTextRole.title2)
        .foregroundColor(color)
        .frame(width: 30)
      
      Text(text)
        .appFont(AppTextRole.body)
        .foregroundColor(.white)
      
      Spacer()
    }
  }
  
  // MARK: - Helper Properties
  
  private var nextCardIndices: [Int] {
    Array((currentIndex + 1)...(currentIndex + 2)).filter { $0 < feeds.count }
  }
  
  private func scaleForCard(at index: Int) -> CGFloat {
    let distance = index - currentIndex
    return max(0.8, 1.0 - CGFloat(distance) * 0.1)
  }
  
  private func offsetForCard(at index: Int) -> CGFloat {
    let distance = index - currentIndex
    return CGFloat(distance) * 20
  }
  
  // MARK: - Gesture Handling
  
  private func handleSwipeGesture(_ value: DragGesture.Value) {
    let translation = value.translation
    let velocity = value.velocity
    
    // Determine swipe direction and action
    let horizontalSwipe = abs(translation.width) > abs(translation.height)
    let verticalSwipe = !horizontalSwipe
    
    if horizontalSwipe {
      if translation.width > swipeThreshold || velocity.width > 300 {
        // Swipe right - subscribe
        handleSubscribeSwipe()
      } else if translation.width < -swipeThreshold || velocity.width < -300 {
        // Swipe left - skip
        handleSkipSwipe()
      } else {
        // Return to center
        resetCardPosition()
      }
    } else if verticalSwipe && (translation.height < -swipeThreshold || velocity.height < -300) {
      // Swipe up - next feed
      handleNextFeedSwipe()
    } else {
      // Return to center
      resetCardPosition()
    }
  }
  
  private func handleSubscribeSwipe() {
    guard currentIndex < feeds.count else { return }
    
    let feed = feeds[currentIndex]
    
    // Animate card off screen to the right
    withAnimation(.easeOut(duration: cardAnimationDuration)) {
      dragOffset = CGSize(width: 500, height: 0)
    }
    
    // Subscribe to feed
    Task {
      await toggleSubscription(feed, force: true)
      await advanceToNextCard()
    }
  }
  
  private func handleSkipSwipe() {
    // Animate card off screen to the left
    withAnimation(.easeOut(duration: cardAnimationDuration)) {
      dragOffset = CGSize(width: -500, height: 0)
    }
    
    // Advance to next card
    Task {
      await advanceToNextCard()
    }
  }
  
  private func handleNextFeedSwipe() {
    // Animate card off screen upward
    withAnimation(.easeOut(duration: cardAnimationDuration)) {
      dragOffset = CGSize(width: 0, height: -500)
    }
    
    // Advance to next card
    Task {
      await advanceToNextCard()
    }
  }
  
  private func resetCardPosition() {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
      dragOffset = .zero
    }
  }
  
  @MainActor
  private func advanceToNextCard() async {
    // Small delay to let animation complete
    try? await Task.sleep(nanoseconds: UInt64(cardAnimationDuration * 1_000_000_000))
    
    currentIndex += 1
    dragOffset = .zero
    
    // Load more feeds if we're near the end
    if currentIndex >= feeds.count - 3 {
      await loadMoreFeeds()
    }
    
    // If we've reached the end, show completion
    if currentIndex >= feeds.count {
      handleEndOfFeedsReached()
    }
  }
  
  private func handleEndOfFeedsReached() {
    // Could show a completion screen or cycle back to beginning
    // For now, dismiss the view
    dismiss()
  }
  
  // MARK: - Data Loading
  
  private func loadFeeds() {
    isLoading = true
    loadingError = nil
    
    Task {
      do {
        guard let client = appState.atProtoClient else {
          throw NSError(domain: "Feed", code: 0, userInfo: [NSLocalizedDescriptionKey: "Client not available"])
        }
        
        let params = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(limit: 30)
        let (responseCode, response) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: params)
        
        await MainActor.run {
          if responseCode == 200, let feedList = response?.feeds {
            feeds = feedList
            // Load subscription status for all feeds
            Task {
              await loadSubscriptionStatuses()
            }
          } else {
            loadingError = "Failed to load feeds. Response code: \(responseCode)"
          }
          isLoading = false
        }
      } catch {
        await MainActor.run {
          loadingError = "Error loading feeds: \(error.localizedDescription)"
          isLoading = false
        }
      }
    }
  }
  
  private func loadMoreFeeds() async {
    // In a real implementation, you'd use cursor-based pagination
    // For now, we'll just ensure we have enough feeds loaded
    if feeds.count < 50 {
      await loadFeeds()
    }
  }
  
  private func loadSubscriptionStatuses() async {
    for feed in feeds {
      let status = await isSubscribedToFeed(feed.uri)
      await MainActor.run {
        subscriptionStatus[feed.uri.uriString()] = status
      }
    }
  }
  
  // MARK: - Subscription Management
  
  private func isSubscribedToFeed(_ feedURI: ATProtocolURI) async -> Bool {
    let feedURIString = feedURI.uriString()
    
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      let pinnedFeeds = preferences.pinnedFeeds
      let savedFeeds = preferences.savedFeeds
      return pinnedFeeds.contains(feedURIString) || savedFeeds.contains(feedURIString)
    } catch {
      return false
    }
  }
  
  private func toggleSubscription(_ feed: AppBskyFeedDefs.GeneratorView, force: Bool = false) async {
    let feedURIString = feed.uri.uriString()
    let currentStatus = subscriptionStatus[feedURIString] ?? false
    
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      
      if currentStatus && !force {
        // Remove from feeds
        await MainActor.run {
          preferences.removeFeed(feedURIString)
        }
      } else {
        // Add to saved feeds
        await MainActor.run {
          preferences.addFeed(feedURIString, pinned: false)
        }
      }
      
      try await appState.preferencesManager.saveAndSyncPreferences(preferences)
      
      // Update local state
      await MainActor.run {
        subscriptionStatus[feedURIString] = !currentStatus || force
      }
      
      // Notify state invalidation bus
      await appState.stateInvalidationBus.notify(.feedListChanged)
      
    } catch {
      logger.error("Failed to toggle feed subscription: \(error.localizedDescription)")
    }
  }
}

// MARK: - Individual Feed Discovery Card

struct FeedDiscoveryCard: View {
  let feed: AppBskyFeedDefs.GeneratorView
  let isSubscribed: Bool
  let onSubscriptionToggle: () async -> Void
  
  @Environment(AppState.self) private var appState
  @State private var previewPosts: [AppBskyFeedDefs.FeedViewPost] = []
  @State private var isLoadingPreview = false
  @State private var previewService: FeedPreviewService?
  
  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        // Feed header
        feedHeader
          .padding()
          .background(Color(.secondarySystemBackground))
        
        // Preview posts section
        if !previewPosts.isEmpty {
          previewPostsSection
        } else if isLoadingPreview {
          loadingPreviewSection
        } else {
          emptyPreviewSection
        }
        
        // Action indicators at bottom
        actionIndicators
          .padding()
          .background(Color(.secondarySystemBackground))
      }
      .background(Color(.systemBackground))
      .clipShape(RoundedRectangle(cornerRadius: 20))
      .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
      .padding(.horizontal, 20)
      .frame(width: geometry.size.width, height: geometry.size.height * 0.8)
    }
    .task {
      await setupPreviewService()
      await loadPreviewPosts()
    }
  }
  
  // MARK: - Feed Header
  
  private var feedHeader: some View {
    VStack(spacing: 16) {
      // Avatar and basic info
      HStack(spacing: 12) {
        AsyncImage(url: URL(string: feed.avatar?.uriString() ?? "")) { image in
          image
            .resizable()
            .scaledToFill()
        } placeholder: {
          feedPlaceholder(for: feed.displayName)
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        
        VStack(alignment: .leading, spacing: 4) {
          Text(feed.displayName)
            .appFont(AppTextRole.title2)
            .fontWeight(.bold)
            .lineLimit(1)
          
          Text("by @\(feed.creator.handle)")
            .appFont(AppTextRole.subheadline)
            .foregroundColor(.secondary)
            .lineLimit(1)
          
          if let likeCount = feed.likeCount {
            HStack(spacing: 4) {
              Image(systemName: "heart.fill")
              Text(formatCount(likeCount))
            }
            .appFont(AppTextRole.caption)
            .foregroundColor(.secondary)
          }
        }
        
        Spacer()
        
        // Subscription status indicator
        if isSubscribed {
          Image(systemName: "checkmark.circle.fill")
            .appFont(AppTextRole.title2)
            .foregroundColor(.green)
        }
      }
      
      // Description
      if let description = feed.description, !description.isEmpty {
        Text(description)
          .appFont(AppTextRole.body)
          .foregroundColor(.primary)
          .multilineTextAlignment(.leading)
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
  
  // MARK: - Preview Posts Section
  
  private var previewPostsSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Recent posts")
          .appFont(AppTextRole.headline)
          .fontWeight(.semibold)
        Spacer()
      }
      .padding(.horizontal)
      .padding(.top)
      
      ScrollView {
        LazyVStack(spacing: 12) {
          ForEach(previewPosts.prefix(4), id: \.post.uri) { feedViewPost in
            CardPreviewPost(feedViewPost: feedViewPost)
              .padding(.horizontal)
          }
        }
      }
    }
    .frame(maxHeight: .infinity)
  }
  
  private var loadingPreviewSection: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Recent posts")
          .appFont(AppTextRole.headline)
          .fontWeight(.semibold)
        Spacer()
      }
      .padding(.horizontal)
      .padding(.top)
      
      VStack(spacing: 12) {
        ForEach(0..<3, id: \.self) { _ in
          RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.2))
            .frame(height: 80)
            .shimmering()
            .padding(.horizontal)
        }
      }
      
      Spacer()
    }
    .frame(maxHeight: .infinity)
  }
  
  private var emptyPreviewSection: some View {
    VStack {
      Spacer()
      
      VStack(spacing: 12) {
        Image(systemName: "doc.text")
          .appFont(AppTextRole.title1)
          .foregroundColor(.secondary)
        
        Text("No preview available")
          .appFont(AppTextRole.headline)
          .foregroundColor(.secondary)
        
        Text("Swipe to explore this feed")
          .appFont(AppTextRole.body)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }
      
      Spacer()
    }
    .frame(maxHeight: .infinity)
  }
  
  // MARK: - Action Indicators
  
  private var actionIndicators: some View {
    HStack(spacing: 24) {
      actionIndicator(
        icon: "arrow.left",
        text: "Skip",
        color: .orange
      )
      
      Spacer()
      
      actionIndicator(
        icon: "arrow.up",
        text: "Next",
        color: .blue
      )
      
      Spacer()
      
      actionIndicator(
        icon: "arrow.right",
        text: isSubscribed ? "Subscribed" : "Subscribe",
        color: isSubscribed ? .green : .green
      )
    }
  }
  
  private func actionIndicator(icon: String, text: String, color: Color) -> some View {
    VStack(spacing: 4) {
      Image(systemName: icon)
        .appFont(AppTextRole.title3)
        .foregroundColor(color)
      
      Text(text)
        .appFont(AppTextRole.caption)
        .foregroundColor(color)
    }
  }
  
  // MARK: - Helper Views
  
  @ViewBuilder
  private func feedPlaceholder(for title: String) -> some View {
    ZStack {
      LinearGradient(
        gradient: Gradient(colors: [
          Color.accentColor.opacity(0.7),
          Color.accentColor.opacity(0.5)
        ]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      
      Text(title.prefix(1).uppercased())
        .appFont(AppTextRole.title1)
        .foregroundColor(.white)
    }
  }
  
  // MARK: - Helper Functions
  
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
    
    do {
      if let service = previewService {
        let posts = try await service.fetchPreview(for: feed.uri)
        await MainActor.run {
          previewPosts = posts
          isLoadingPreview = false
        }
      }
    } catch {
      await MainActor.run {
        isLoadingPreview = false
      }
    }
  }
}

// MARK: - Card Preview Post

struct CardPreviewPost: View {
  let feedViewPost: AppBskyFeedDefs.FeedViewPost
  
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
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
        .frame(width: 32, height: 32)
        .clipShape(Circle())
      } else {
        Circle()
          .fill(Color.gray.opacity(0.3))
          .frame(width: 32, height: 32)
      }
      
      VStack(alignment: .leading, spacing: 2) {
        // Author info
        Text(feedViewPost.post.author.displayName ?? feedViewPost.post.author.handle.description)
          .appFont(AppTextRole.subheadline)
          .fontWeight(.medium)
          .lineLimit(1)
        
        // Post content
        if case .knownType(let record) = feedViewPost.post.record,
           let feedPost = record as? AppBskyFeedPost {
            Text(feedPost.text)
            .appFont(AppTextRole.body)
            .foregroundColor(.primary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
        }
        
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
        .padding(.top, 2)
      }
      
      Spacer(minLength: 0)
    }
    .padding(8)
    .background(Color(.tertiarySystemBackground))
    .cornerRadius(8)
  }
}

// MARK: - Preview

#Preview {
  FeedDiscoveryCardsView()
}
