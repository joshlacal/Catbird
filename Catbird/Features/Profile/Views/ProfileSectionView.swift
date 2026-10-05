import NukeUI
import Petrel
import SwiftUI

struct ProfileSectionView: View {
    let viewModel: ProfileViewModel
    let tab: ProfileTab
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    @State private var isInitialLoading = true
    @State private var hasLoaded = false
    @State private var loadError: Error?
    @State private var showingCreateStarterPack = false
    
    private static let baseUnit: CGFloat = 3
    var body: some View {
        Group {
            if isInitialLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                ContentUnavailableView {
                    Label("Couldn’t Load \(tab.title)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(UserFacingError.message(for: error, action: "load \(tab.title.lowercased())") ?? "Check your connection and try again.")
                } actions: {
                    Button("Try Again") {
                        Task { await loadContent() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                // Main content view once loading is complete
                contentForTab
            }
        }
        .navigationTitle(tab.title)
        .task {
            // Load once; returning from a pushed list or post shouldn't reload and flash a spinner.
            guard !hasLoaded else { return }
            await loadContent()
        }
        .sheet(isPresented: $showingCreateStarterPack) {
            StarterPackWizardView(mode: .create) { uri in
                path.append(NavigationDestination.starterPack(uri))
                Task {
                    try? await viewModel.refreshStarterPacks()
                }
            }
        }
    }
    
    // Loads (or reloads) the first page for this section and records any failure.
    private func loadContent() async {
        if !hasLoaded {
            isInitialLoading = true
        }
        loadError = nil

        do {
            try await refreshContent()
        } catch {
            if !(error is CancellationError) {
                loadError = error
            }
        }

        hasLoaded = true
        isInitialLoading = false
    }

    private func refreshContent() async throws {
        switch tab {
        case .likes:
            try await viewModel.refreshLikes()
        case .lists:
            try await viewModel.refreshLists()
        case .starterPacks:
            try await viewModel.refreshStarterPacks()
        case .feeds:
            try await viewModel.refreshFeeds()
        default:
            break
        }
    }
    
    // Content views organized for better maintainability
    @ViewBuilder
    private var contentForTab: some View {
        List {
            switch tab {
            case .likes:
                likesList
            case .lists:
                listsList
            case .starterPacks:
                starterPacksList
            case .feeds:
                feedsList
            default:
                Text("Content not available")
                    .padding()
            }
        }
        .listStyle(.plain)
        .navigationTitle(tab.title)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
        .refreshable {
            await loadContent()
        }
    }

  // MARK: - Content Views

  @ViewBuilder
  private var likesList: some View {
      if viewModel.isCurrentUser {
          
          if viewModel.isLoadingLikes && viewModel.likes.isEmpty {
              ProgressView("Loading…")
                  .frame(maxWidth: .infinity, minHeight: 100)
                  .padding()
          } else if viewModel.likes.isEmpty {
              emptyContentView("No Likes", "You haven’t liked any posts yet.")
          } else {
              ForEach(viewModel.likes, id: \.post.uri) { post in
                  FeedPost(post: post, path: $path)
                  
                  // Load more when reaching the end
                  if post == viewModel.likes.last && viewModel.hasMoreLikes {
                      Color.clear.frame(height: 20)
                          .onAppear {
                              Task { await viewModel.loadMoreLikes() }
                          }
                  }
              }
              
              // Loading indicator for pagination
              if viewModel.isLoadingLikes && viewModel.hasMoreLikes {
                  ProgressView()
                      .padding()
                      .frame(maxWidth: .infinity)
              }
          }
      } else {

          if viewModel.isLoadingLikes && viewModel.otherUserLikes.isEmpty {
              ProgressView("Loading…")
                  .frame(maxWidth: .infinity, minHeight: 100)
                  .padding()
          } else if viewModel.otherUserLikes.isEmpty {
              emptyContentView("No Likes", "This user hasn’t liked any posts yet.")
          } else {
              ForEach(viewModel.otherUserLikes, id: \.uri) { post in
                  PostView(post: post, grandparentAuthor: nil, isParentPost: false, isSelectable: false, path: $path, appState: appState)
                      .padding(.top, ProfileSectionView.baseUnit * 3)
                    .padding(.horizontal, ProfileSectionView.baseUnit * 1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    // Make sure interactions pass through correctly
                    .contentShape(Rectangle())
                    .onTapGesture {
                        path.append(NavigationDestination.post(post.uri))
                    }

                  // Load more when reaching the end
                  if post == viewModel.otherUserLikes.last && viewModel.hasMoreLikes {
                      Color.clear.frame(height: 20)
                          .onAppear {
                              Task { await viewModel.loadMoreLikes() }
                          }
                  }
              }
              
              // Loading indicator for pagination
              if viewModel.isLoadingLikes && viewModel.hasMoreLikes {
                  ProgressView()
                      .padding()
                      .frame(maxWidth: .infinity)
              }
          }

      }
  }

  @ViewBuilder
  private var listsList: some View {
    if viewModel.isLoadingSection && viewModel.lists.isEmpty {
      ProgressView("Loading…")
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
    } else if viewModel.lists.isEmpty {
      emptyContentView("No Lists", viewModel.isCurrentUser ? "You haven’t created any lists yet." : "This user hasn’t created any lists yet.")
    } else {
      ForEach(viewModel.lists, id: \.uri) { list in
        Button {
          path.append(NavigationDestination.listFeed(list.uri))
        } label: {
          ListRow(list: list)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        // Load more when reaching the end
        if list == viewModel.lists.last && viewModel.hasMoreLists {
          Color.clear.frame(height: 20)
            .onAppear {
              Task { await viewModel.loadMoreLists() }
            }
        }
      }

      // Loading indicator for pagination
      if viewModel.isLoadingSection && viewModel.hasMoreLists {
        ProgressView()
          .padding()
          .frame(maxWidth: .infinity)
      }
    }
  }

  @ViewBuilder
  private var starterPacksList: some View {
    if viewModel.isLoadingSection && viewModel.starterPacks.isEmpty {
      ProgressView("Loading…")
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
    } else if viewModel.starterPacks.isEmpty {
      VStack(spacing: 16) {
        emptyContentView("No Starter Packs", viewModel.isCurrentUser ? "You haven’t created any starter packs yet." : "This user hasn’t created any starter packs yet.")
        
        if viewModel.isCurrentUser {
          Button {
            showingCreateStarterPack = true
          } label: {
            HStack(spacing: 8) {
              Image(systemName: "plus")
              Text("Create Starter Pack")
                .fontWeight(.semibold)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.accentColor))
            .foregroundColor(.white)
          }
          .buttonStyle(.plain)
        }
      }
    } else {
      if viewModel.isCurrentUser {
        Button {
          showingCreateStarterPack = true
        } label: {
          HStack {
            Image(systemName: "plus.circle.fill")
              .foregroundColor(.accentColor)
            Text("Create Starter Pack")
              .appFont(AppTextRole.subheadline)
              .fontWeight(.semibold)
              .foregroundColor(.accentColor)
            Spacer()
          }
          .padding(.horizontal)
          .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        
        Divider()
      }
      
      ForEach(viewModel.starterPacks, id: \.uri) { pack in
        Button {
          path.append(NavigationDestination.starterPack(pack.uri))
        } label: {
          StarterPackRowView(pack: pack)
        }

        // Load more when reaching the end
        if pack == viewModel.starterPacks.last && viewModel.hasMoreStarterPacks {
          Color.clear.frame(height: 20)
            .onAppear {
              Task { await viewModel.loadStarterPacks() }
            }
        }
      }

      // Loading indicator for pagination
      if viewModel.isLoadingSection && viewModel.hasMoreStarterPacks {
        ProgressView()
          .padding()
          .frame(maxWidth: .infinity)
      }
    }
  }
  @ViewBuilder
  private var feedsList: some View {
    if viewModel.isLoadingSection && viewModel.feeds.isEmpty {
      ProgressView("Loading…")
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
    } else if viewModel.feeds.isEmpty {
      emptyContentView("No Feeds", viewModel.isCurrentUser ? "You haven’t created any feeds yet." : "This user hasn’t created any feeds yet.")
    } else {
      ForEach(viewModel.feeds, id: \.uri) { feed in
        Button {
          path.append(NavigationDestination.feed(feed.uri))
        } label: {
          FeedRowView(feed: feed)
        }
        .buttonStyle(.plain)

        // Load more when reaching the end
        if feed == viewModel.feeds.last && viewModel.hasMoreFeeds {
          Color.clear.frame(height: 20)
            .onAppear {
              Task { await viewModel.loadMoreFeeds() }
            }
        }
      }

      // Loading indicator for pagination
      if viewModel.isLoadingSection && viewModel.hasMoreFeeds {
        ProgressView()
          .padding()
          .frame(maxWidth: .infinity)
      }
    }
  }

  @ViewBuilder
  private func emptyContentView(_ title: String, _ message: String) -> some View {
    VStack(spacing: 16) {
      Spacer()

      Image(systemName: "square.stack.3d.up.slash")
        .appFont(size: 48)
        .foregroundColor(.secondary)

      Text(title)
        .appFont(AppTextRole.title3)
        .fontWeight(.semibold)

      Text(message)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)

      Spacer()
    }
    .frame(maxWidth: .infinity, minHeight: 300)
  }
}

/// Shows a profile's More section for any account, independent of which profile screen
/// registered the navigation destination.
struct ProfileSectionHostView: View {
    let tab: ProfileTab
    @Binding var path: NavigationPath
    @State private var viewModel: ProfileViewModel

    init(did: String, tab: ProfileTab, appState: AppState, path: Binding<NavigationPath>) {
        self.tab = tab
        self._path = path
        self._viewModel = State(initialValue: ProfileViewModel(
            client: appState.atProtoClient,
            userDID: did,
            currentUserDID: appState.userDID
        ))
    }

    var body: some View {
        Group {
            if viewModel.profile != nil {
                ProfileSectionView(viewModel: viewModel, tab: tab, path: $path)
            } else if let error = viewModel.error {
                ContentUnavailableView {
                    Label("Couldn’t Load \(tab.title)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text((error as? ProfileError)?.errorDescription
                        ?? UserFacingError.message(for: error, action: "load this profile")
                        ?? "Try again.")
                } actions: {
                    Button("Try Again") {
                        Task { await viewModel.loadProfile() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .navigationTitle(tab.title)
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(tab.title)
            }
        }
        .task {
            if viewModel.profile == nil {
                await viewModel.loadProfile()
            }
        }
    }
}

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
        ProfileSectionView(
          viewModel: ProfileViewModel(
            client: nil,
            userDID: "did:example:user",
            currentUserDID: "did:example:current"
          ),
          tab: .likes,
          path: .constant(NavigationPath())
        )
      }
  }
}

