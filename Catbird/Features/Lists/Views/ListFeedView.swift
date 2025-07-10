import SwiftUI
import Petrel
import OSLog
import NukeUI

@Observable
final class ListFeedViewModel {
  // MARK: - Properties
  
  private let appState: AppState
  private let listURI: String
  private let logger = Logger(subsystem: "blue.catbird", category: "ListFeedView")
  
  // Core data
  var listDetails: AppBskyGraphDefs.ListView?
  var feedPosts: [AppBskyFeedDefs.FeedViewPost] = []
  var members: [AppBskyActorDefs.ProfileView] = []
  
  // State
  var isLoading = false
  var isLoadingMore = false
  var isRefreshing = false
  var errorMessage: String?
  var showingError = false
  var showingMembersList = false
  
  // Pagination
  var cursor: String?
  var hasMorePosts = true
  
  // MARK: - Computed Properties
  
  var hasPosts: Bool {
    !feedPosts.isEmpty
  }
  
  var isOwnList: Bool {
    guard let listDetails = listDetails else { return false }
    return listDetails.creator.did.didString() == appState.currentUserDID
  }
  
  // MARK: - Initialization
  
  init(listURI: String, appState: AppState) {
    self.listURI = listURI
    self.appState = appState
  }
  
  // MARK: - Data Loading
  
  @MainActor
  func loadInitialData() async {
    guard !isLoading else { return }
    
    isLoading = true
    errorMessage = nil
    cursor = nil
    
    do {
      // Load list details and members concurrently
      async let listDetailsTask = appState.listManager.getListDetails(listURI)
      async let membersTask = appState.listManager.getListMembers(listURI)
      
      listDetails = try await listDetailsTask
      members = try await membersTask
      
      // Load feed posts from list members
      await loadFeedPosts()
      
      logger.info("Loaded list feed data: \(self.feedPosts.count) posts from \(self.members.count) members")
      
    } catch {
      logger.error("Failed to load list feed data: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
    
    isLoading = false
  }
  
  @MainActor
  func refreshData() async {
    guard !isRefreshing else { return }
    
    isRefreshing = true
    cursor = nil
    
    do {
      // Refresh list details and members
      async let listDetailsTask = appState.listManager.getListDetails(listURI, forceRefresh: true)
      async let membersTask = appState.listManager.getListMembers(listURI, forceRefresh: true)
      
      listDetails = try await listDetailsTask
      members = try await membersTask
      
      // Refresh feed posts
      await loadFeedPosts(refresh: true)
      
      logger.info("Refreshed list feed data")
      
    } catch {
      logger.error("Failed to refresh list feed data: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingError = true
    }
    
    isRefreshing = false
  }
  
  @MainActor
  func loadMorePosts() async {
    guard !isLoadingMore && hasMorePosts && cursor != nil else { return }
    
    isLoadingMore = true
    await loadFeedPosts()
    isLoadingMore = false
  }
  
  @MainActor
  private func loadFeedPosts(refresh: Bool = false) async {
    guard let client = appState.atProtoClient else { return }
    
    do {
      // Get posts from list members
      // This is a simplified implementation - in reality, you might want to
      // fetch posts from each member and aggregate them, or use a dedicated list feed API
      
      let memberDIDs = members.map { $0.did.didString() }
      
      if memberDIDs.isEmpty {
        feedPosts = []
        hasMorePosts = false
        return
      }
      
      // Load feed posts from list members using timeline filtering
      let (responseCode, timelineData) = try await client.app.bsky.feed.getTimeline(
        input: .init(
          algorithm: nil,
          limit: 20,
          cursor: refresh ? nil : cursor
        )
      )
      
      guard responseCode == 200, let timelineData = timelineData else {
        logger.warning("Failed to load list feed posts")
        return
      }
      
      // Filter posts to only include those from list members
      let filteredPosts = timelineData.feed.filter { feedPost in
        memberDIDs.contains(feedPost.post.author.did.didString())
      }
      
      if refresh {
        feedPosts = filteredPosts
      } else {
        feedPosts.append(contentsOf: filteredPosts)
      }
      
      cursor = timelineData.cursor
      hasMorePosts = timelineData.cursor != nil && !filteredPosts.isEmpty
      
      logger.debug("Loaded \(filteredPosts.count) list feed posts")
      
    } catch {
      logger.error("Failed to load list feed posts: \(error.localizedDescription)")
      if refresh {
        errorMessage = error.localizedDescription
        showingError = true
      }
    }
  }
}

struct ListFeedView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var viewModel: ListFeedViewModel
  @State private var navigationPath = NavigationPath()
  
  let listURI: String
  
  init(listURI: String) {
    self.listURI = listURI
    self._viewModel = State(wrappedValue: ListFeedViewModel(listURI: listURI, appState: AppState.shared))
  }
  
  var body: some View {
    NavigationStack(path: $navigationPath) {
      contentView
        .navigationTitle(viewModel.listDetails?.name ?? "List Feed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
              Button {
                viewModel.showingMembersList = true
              } label: {
                Label("View Members", systemImage: "person.2")
              }
              
              if viewModel.isOwnList {
                Button {
                  navigationPath.append(NavigationDestination.editList(try! ATProtocolURI(uriString: listURI)))
                } label: {
                  Label("Edit List", systemImage: "pencil")
                }
                
                Button {
                  navigationPath.append(NavigationDestination.listMembers(try! ATProtocolURI(uriString: listURI)))
                } label: {
                  Label("Manage Members", systemImage: "person.2.badge.gearshape")
                }
              }
            } label: {
              Image(systemName: "ellipsis.circle")
            }
          }
        }
        .onAppear {
          viewModel = ListFeedViewModel(listURI: listURI, appState: appState)
          Task {
            await viewModel.loadInitialData()
          }
        }
        .refreshable {
          await viewModel.refreshData()
        }
        .alert("Error", isPresented: $viewModel.showingError) {
          Button("OK") {
            viewModel.showingError = false
          }
        } message: {
          if let errorMessage = viewModel.errorMessage {
            Text(errorMessage)
          }
        }
        .sheet(isPresented: $viewModel.showingMembersList) {
          if let listDetails = viewModel.listDetails {
            ListMemberManagementView(listURI: listURI)
          }
        }
        .navigationDestination(for: NavigationDestination.self) { destination in
          NavigationHandler.viewForDestination(destination, path: $navigationPath, appState: appState, selectedTab: .constant(0))
        }
    }
  }
  
  @ViewBuilder
  private var contentView: some View {
    if viewModel.isLoading && viewModel.feedPosts.isEmpty {
      loadingView
    } else if !viewModel.hasPosts {
      emptyStateView
    } else {
      feedView
    }
  }
  
  private var loadingView: some View {
    VStack(spacing: 16) {
      ProgressView()
        .scaleEffect(1.5)
      Text("Loading list feed...")
        .font(.headline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  private var emptyStateView: some View {
    VStack(spacing: 24) {
      Image(systemName: "list.bullet.rectangle")
        .font(.system(size: 64))
        .foregroundStyle(.secondary)
      
      VStack(spacing: 8) {
        Text("No Posts Yet")
          .font(.title2)
          .fontWeight(.semibold)
        
        Text(viewModel.members.isEmpty ? 
             "This list has no members yet" :
             "Members of this list haven't posted recently")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      
      if viewModel.members.isEmpty && viewModel.isOwnList {
        Button("Add Members") {
          navigationPath.append(NavigationDestination.listMembers(try! ATProtocolURI(uriString: listURI)))
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  
  private var feedView: some View {
    VStack(spacing: 0) {
      // List Header
      if let listDetails = viewModel.listDetails {
        listHeaderView(listDetails)
      }
      
      // Feed Posts
      List {
        ForEach(viewModel.feedPosts, id: \.post.uri) { feedPost in
          ListFeedPostRow(
            feedPost: feedPost,
            onTap: {
              navigationPath.append(NavigationDestination.post(feedPost.post.uri))
            },
            onProfileTap: {
              navigationPath.append(NavigationDestination.profile(feedPost.post.author.did.didString()))
            }
          )
          .listRowSeparator(.hidden)
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
          .onAppear {
            // Load more when reaching the end
            if feedPost == viewModel.feedPosts.last {
              Task {
                await viewModel.loadMorePosts()
              }
            }
          }
        }
        
        // Loading indicator for pagination
        if viewModel.isLoadingMore {
          HStack {
            Spacer()
            ProgressView()
              .padding()
            Spacer()
          }
          .listRowSeparator(.hidden)
        }
      }
      .listStyle(.plain)
    }
  }
  
  private func listHeaderView(_ listDetails: AppBskyGraphDefs.ListView) -> some View {
    VStack(spacing: 12) {
      HStack(spacing: 12) {
        // List Avatar
        LazyImage(url: listDetails.avatar?.url) { state in
          if let image = state.image {
            image
              .resizable()
              .scaledToFill()
          } else {
            listPlaceholderIcon
          }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        
        VStack(alignment: .leading, spacing: 4) {
          Text(listDetails.name)
            .font(.title2)
            .fontWeight(.bold)
          
          if let description = listDetails.description, !description.isEmpty {
            Text(description)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
          
          HStack {
            Text("\(viewModel.members.count) members")
              .font(.caption)
              .foregroundStyle(.tertiary)
            
            Spacer()
            
            purposeBadge(listDetails.purpose)
          }
        }
        
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      
      Divider()
    }
    .background(.regularMaterial)
  }
  
  private var listPlaceholderIcon: some View {
    RoundedRectangle(cornerRadius: 12)
      .fill(.secondary.opacity(0.3))
      .overlay {
        Image(systemName: "list.bullet")
          .font(.title2)
          .foregroundStyle(.secondary)
      }
  }
  
  private func purposeBadge(_ purpose: AppBskyGraphDefs.ListPurpose) -> some View {
    HStack(spacing: 4) {
      Image(systemName: iconForPurpose(purpose))
        .font(.caption2)
      Text(textForPurpose(purpose))
        .font(.caption2)
        .fontWeight(.medium)
    }
    .foregroundStyle(colorForPurpose(purpose))
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(colorForPurpose(purpose).opacity(0.2))
    .clipShape(Capsule())
  }
  
  private func iconForPurpose(_ purpose: AppBskyGraphDefs.ListPurpose) -> String {
    switch purpose {
    case .appbskygraphdefscuratelist:
      return "star.fill"
    case .appbskygraphdefsmodlist:
      return "shield.lefthalf.filled"
    case .appbskygraphdefsreferencelist:
      return "bookmark.fill"
    default:
      return "questionmark.circle"
    }
  }
  
  private func textForPurpose(_ purpose: AppBskyGraphDefs.ListPurpose) -> String {
    switch purpose {
    case .appbskygraphdefscuratelist:
      return "Curated"
    case .appbskygraphdefsmodlist:
      return "Moderation"
    case .appbskygraphdefsreferencelist:
      return "Reference"
    default:
      return "Unknown"
    }
  }
  
  private func colorForPurpose(_ purpose: AppBskyGraphDefs.ListPurpose) -> Color {
    switch purpose {
    case .appbskygraphdefscuratelist:
      return .yellow
    case .appbskygraphdefsmodlist:
      return .red
    case .appbskygraphdefsreferencelist:
      return .blue
    default:
      return .gray
    }
  }
}

// MARK: - Supporting Views

struct ListFeedPostRow: View {
  let feedPost: AppBskyFeedDefs.FeedViewPost
  let onTap: () -> Void
  let onProfileTap: () -> Void
  
  var body: some View {
    Button(action: onTap) {
      VStack(alignment: .leading, spacing: 8) {
        // Author Header
        HStack(spacing: 8) {
          Button(action: onProfileTap) {
            LazyImage(url: feedPost.post.author.avatar?.url) { state in
              if let image = state.image {
                image
                  .resizable()
                  .scaledToFill()
              } else {
                Circle()
                  .fill(.secondary.opacity(0.3))
              }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
          }
          .buttonStyle(.plain)
          
          VStack(alignment: .leading, spacing: 1) {
            Text(feedPost.post.author.displayName ?? feedPost.post.author.handle.description)
              .font(.subheadline)
              .fontWeight(.medium)
              .lineLimit(1)
            
            Text("@\(feedPost.post.author.handle)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          
          Spacer()
          
            Text(feedPost.post.indexedAt.date.formatted(.relative(presentation: .numeric)))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        
        // Post Content
        if case let .knownType(bskyPost) = feedPost.post.record,
           let post = bskyPost as? AppBskyFeedPost {
          Text(post.text)
            .font(.subheadline)
            .lineLimit(6)
            .multilineTextAlignment(.leading)
        }
        
        // Engagement Stats
        HStack(spacing: 16) {
          HStack(spacing: 4) {
            Image(systemName: "heart")
              .font(.caption)
            Text("\(feedPost.post.likeCount ?? 0)")
              .font(.caption)
          }
          .foregroundStyle(.secondary)
          
          HStack(spacing: 4) {
            Image(systemName: "arrowshape.turn.up.right")
              .font(.caption)
            Text("\(feedPost.post.repostCount ?? 0)")
              .font(.caption)
          }
          .foregroundStyle(.secondary)
          
          HStack(spacing: 4) {
            Image(systemName: "bubble.left")
              .font(.caption)
            Text("\(feedPost.post.replyCount ?? 0)")
              .font(.caption)
          }
          .foregroundStyle(.secondary)
          
          Spacer()
        }
      }
      .padding(.vertical, 8)
    }
    .buttonStyle(.plain)
  }
}
