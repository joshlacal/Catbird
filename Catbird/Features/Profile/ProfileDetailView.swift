//import NukeUI
//import OSLog
//import Petrel
//import SwiftUI
//
//// MARK: - Profile Detail View (for viewing other profiles when tapped)
//struct ProfileDetailView: View {
//  @Environment(AppState.self) private var appState
//  let did: String
//  @State private var viewModel: ProfileViewModel
//  @Binding var selectedTab: Int
//  @Binding private var navigationPath: NavigationPath
//    @State private var isShowingReportSheet = false
//
//    init(did: String, selectedTab: Binding<Int>, appState: AppState, path: Binding<NavigationPath>) {
//    self.did = did
//    _viewModel = State(wrappedValue: ProfileViewModel(client: appState.atProtoClient, userDID: did))
//    self._selectedTab = selectedTab
//    _navigationPath = path
//  }
//
//  var body: some View {
//    Group {
//      if viewModel.isLoading && viewModel.profile == nil {
//        loadingView
//      } else if let profile = viewModel.profile {
//        profileContent(profile)
//              .sheet(isPresented: $isShowingReportSheet) {
//                  if let profile = viewModel.profile,
//                  let atProtoClient = appState.atProtoClient {
//                      let reportingService = ReportingService(client: atProtoClient)
//                      
//                      ReportProfileView(
//                          profile: profile,
//                          reportingService: reportingService,
//                          onComplete: { success in
//                              isShowingReportSheet = false
//                              // Optionally show feedback about success/failure
//                          }
//                      )
//                  }
//              }
//      } else {
//        errorView
//      }
//    }
//    .navigationTitle(viewModel.profile != nil ? "@\(viewModel.profile!.handle)" : "Profile")
//    .navigationBarTitleDisplayMode(.inline)
//    .refreshable {
//      await viewModel.loadProfile()
//    }
//    .toolbar {
//      if let profile = viewModel.profile {
//        ToolbarItem(placement: .principal) {
//          Text(profile.displayName ?? profile.handle)
//            .font(.headline)
//        }
//      }
//    }
//    .task {
//      await viewModel.loadProfile()
//    }
//  }
//    
//    private func showReportProfileSheet() {
//        isShowingReportSheet = true
//    }
//
//
//  private var loadingView: some View {
//    VStack {
//      ProgressView()
//        .scaleEffect(1.5)
//      Text("Loading profile...")
//        .foregroundColor(.secondary)
//        .padding(.top)
//    }
//    .frame(maxWidth: .infinity, maxHeight: .infinity)
//  }
//
//  private var errorView: some View {
//    VStack(spacing: 16) {
//      Image(systemName: "exclamationmark.triangle")
//        .font(.system(size: 48))
//        .foregroundColor(.orange)
//
//      Text("Couldn't Load Profile")
//        .font(.title2)
//        .fontWeight(.semibold)
//
//      if let error = viewModel.error {
//        Text(error.localizedDescription)
//          .font(.subheadline)
//          .foregroundColor(.secondary)
//          .multilineTextAlignment(.center)
//          .padding(.horizontal)
//      }
//
//      Button(action: {
//        Task {
//          await viewModel.loadProfile()
//        }
//      }) {
//        Text("Try Again")
//          .padding(.horizontal, 24)
//          .padding(.vertical, 10)
//          .background(Color.accentColor)
//          .foregroundColor(.white)
//          .cornerRadius(8)
//      }
//      .padding(.top, 8)
//    }
//    .frame(maxWidth: .infinity, maxHeight: .infinity)
//  }
//
//    @ViewBuilder
//    private func profileContent(_ profile: AppBskyActorDefs.ProfileViewDetailed) -> some View {
//        ScrollView {
//            VStack(alignment: .leading, spacing: 0) {
//                // Profile header
//                ProfileHeader(
//                    profile: profile,
//                    viewModel: viewModel
//                )
//                .contextMenu {
//                    // Other context menu items
//                    
//                    Button(role: .destructive) {
//                        showReportProfileSheet()
//                    } label: {
//                        Label("Report User", systemImage: "flag")
//                    }
//                }
//
//                // Add report option in more menu
//                .toolbar {
//                    ToolbarItem(placement: .primaryAction) {
//                        Menu {
//                            // Existing menu items...
//                            
//                            // Add report button
//                            Button(role: .destructive) {
//                                showReportProfileSheet()
//                            } label: {
//                                Label("Report Profile", systemImage: "flag")
//                            }
//                        } label: {
//                            Image(systemName: "ellipsis")
//                        }
//                    }
//                }
//
//        // Tab selector for posts, likes, etc.
//        ProfileTabSelector(selectedTab: $viewModel.selectedProfileTab, onTabChange: { tab in
//          Task {
//            switch tab {
//            case .posts:
//              if viewModel.posts.isEmpty { await viewModel.loadPosts() }
//            case .replies:
//              if viewModel.replies.isEmpty { await viewModel.loadReplies() }
//            case .media:
//              if viewModel.postsWithMedia.isEmpty { await viewModel.loadMediaPosts() }
//            case .likes:
//              if viewModel.likes.isEmpty { await viewModel.loadLikes() }
//            case .lists:
//              if viewModel.lists.isEmpty { await viewModel.loadLists() }
//            }
//          }
//        })
//        .padding(.top)
//        
//        // Content based on selected tab
//        profileTabContent
//
//        // Loading indicator for feed pagination
//        if viewModel.isLoadingMorePosts {
//          ProgressView()
//            .frame(maxWidth: .infinity, alignment: .center)
//            .padding()
//        }
//      }
//    }
//    .scrollIndicators(.visible)
//  }
//
//  @ViewBuilder
//  private var profileTabContent: some View {
//    switch viewModel.selectedProfileTab {
//    case .posts:
//      postsList
//    case .replies:
//      repliesList
//    case .media:
//      mediaList
//    case .likes:
//      likesList
//    case .lists:
//      listsList
//    }
//  }
//  
//  // Lists for different content types
//  private var postsList: some View {
//    postRows(posts: viewModel.posts, emptyMessage: "No posts") {
//      await viewModel.loadPosts()
//    }
//  }
//  
//  private var repliesList: some View {
//    postRows(posts: viewModel.replies, emptyMessage: "No replies") {
//      await viewModel.loadReplies()
//    }
//  }
//  
//  private var mediaList: some View {
//    postRows(posts: viewModel.postsWithMedia, emptyMessage: "No media posts") {
//      await viewModel.loadMediaPosts()
//    }
//  }
//  
//  private var likesList: some View {
//    postRows(posts: viewModel.likes, emptyMessage: "No liked posts") {
//      await viewModel.loadLikes()
//    }
//  }
//  
//  @ViewBuilder
//  private var listsList: some View {
//    if viewModel.isLoading && viewModel.lists.isEmpty {
//      ProgressView("Loading lists...")
//        .frame(maxWidth: .infinity, minHeight: 100)
//        .padding()
//    } else if viewModel.lists.isEmpty {
//      emptyContentView("No Lists", "This user hasn't created any lists yet.")
//    } else {
//      LazyVStack(spacing: 0) {
//        ForEach(viewModel.lists, id: \.uri) { list in
//          Button {
//            navigationPath.append(NavigationDestination.list(list.uri))
//          } label: {
//            ListRow(list: list)
//              .contentShape(Rectangle())
//          }
//          .buttonStyle(.plain)
//          
//          Divider()
//          
//          // Load more when reaching the end
//          if list == viewModel.lists.last && !viewModel.isLoadingMorePosts {
//            Color.clear.frame(height: 20)
//              .onAppear {
//                Task { await viewModel.loadLists() }
//              }
//          }
//        }
//      }
//      .onAppear {
//        if viewModel.lists.isEmpty && !viewModel.isLoadingMorePosts {
//          Task {
//            await viewModel.loadLists()
//          }
//        }
//      }
//    }
//  }
//  
//  // Reusable post rows builder
//  @ViewBuilder
//  private func postRows(posts: [AppBskyFeedDefs.FeedViewPost], emptyMessage: String, load: @escaping () async -> Void) -> some View {
//    if viewModel.isLoading && posts.isEmpty {
//      ProgressView("Loading...")
//        .frame(maxWidth: .infinity, minHeight: 100)
//        .padding()
//    } else if posts.isEmpty {
//      emptyContentView("No Content", emptyMessage)
//        .padding(.top, 40)
//        .onAppear {
//          Task { await load() }
//        }
//    } else {
//      LazyVStack(spacing: 0) {
//        // Post rows
//        ForEach(posts, id: \.post.uri) { post in
//          Button {
//            navigationPath.append(NavigationDestination.post(post.post.uri))
//          } label: {
//            FeedPost(post: post, path: $navigationPath)
//              .contentShape(Rectangle())
//              .fixedSize(horizontal: false, vertical: true)
//          }
//          .buttonStyle(.plain)
//          
//          Divider()
//          
//          // Load more when reaching the end
//          if post == posts.last && !viewModel.isLoadingMorePosts {
//            Color.clear.frame(height: 20)
//              .onAppear {
//                Task { await load() }
//              }
//          }
//        }
//      }
//      .onAppear {
//        if posts.isEmpty && !viewModel.isLoading {
//          Task { await load() }
//        }
//      }
//    }
//  }
//
//  private func emptyContentView(_ title: String, _ message: String) -> some View {
//    VStack(spacing: 16) {
//      Spacer()
//
//      Image(systemName: "square.stack.3d.up.slash")
//        .font(.system(size: 48))
//        .foregroundColor(.secondary)
//
//      Text(title)
//        .font(.title3)
//        .fontWeight(.semibold)
//
//      Text(message)
//        .foregroundColor(.secondary)
//        .multilineTextAlignment(.center)
//        .padding(.horizontal)
//
//      Spacer()
//    }
//    .frame(maxWidth: .infinity, minHeight: 300)
//  }
//}
