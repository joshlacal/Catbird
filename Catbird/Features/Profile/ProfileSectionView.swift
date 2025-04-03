import NukeUI
import Petrel
import SwiftUI

struct ProfileSectionView: View {
    // Create a new instance to avoid shared state issues
    let viewModel: ProfileViewModel
    let tab: ProfileTab
    @Binding var path: NavigationPath
    
    // Add state tracking to diagnose loading issues
    @State private var isInitialLoading = true
    @State private var loadError: Error? = nil

    var body: some View {
        Group {
            if isInitialLoading {
                ProgressView("Loading \(tab.title.lowercased())...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    
                    Text("Could not load content")
                        .font(.headline)
                    
                    Text(error.localizedDescription)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Button("Try Again") {
                        Task { await loadContent() }
                    }
                    .padding()
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .padding()
            } else {
                // Main content view once loading is complete
                contentForTab
            }
        }
        .navigationTitle(tab.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Load content on appearance
            await loadContent()
        }
    }
    
    // Centralized content loading function to handle all cases
    private func loadContent() async {
        isInitialLoading = true
        loadError = nil
        
            switch tab {
            case .likes:
                // Force reload without isEmpty check
                await viewModel.loadLikes()
            case .lists:
                await viewModel.loadLists()
            case .starterPacks:
                await viewModel.loadStarterPacks()
            default:
                break
            }
            
            // After successful loading
            isInitialLoading = false
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
            default:
                Text("Content not available")
                    .padding()
            }
        }
        .listStyle(.plain)
        .navigationTitle(tab.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await loadContent()
        }
    }

  // MARK: - Content Views

  @ViewBuilder
  private var likesList: some View {
    if viewModel.isLoading && viewModel.likes.isEmpty {
      ProgressView("Loading liked posts...")
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
    } else if viewModel.likes.isEmpty {
      emptyContentView("No Likes", "This user hasn't liked any posts yet.")
    } else {
        ForEach(viewModel.likes, id: \.post.uri) { post in
            FeedPost(post: post, path: $path)
                .applyListRowModifiers(id: post.id)

          // Load more when reaching the end
          if post == viewModel.likes.last && !viewModel.isLoadingMorePosts {
            Color.clear.frame(height: 20)
              .onAppear {
                Task { await viewModel.loadLikes() }
              }
          }
        }

        // Loading indicator for pagination
        if viewModel.isLoadingMorePosts {
          ProgressView()
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
  }

  @ViewBuilder
  private var listsList: some View {
    if viewModel.isLoading && viewModel.lists.isEmpty {
      ProgressView("Loading lists...")
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
    } else if viewModel.lists.isEmpty {
      emptyContentView("No Lists", "This user hasn't created any lists yet.")
    } else {
      LazyVStack(spacing: 0) {
        ForEach(viewModel.lists, id: \.uri) { list in
          ListRow(list: list)
                .applyListRowModifiers(id: list.uri.uriString())

          // Load more when reaching the end
          if list == viewModel.lists.last && !viewModel.isLoadingMorePosts {
            Color.clear.frame(height: 20)
              .onAppear {
                Task { await viewModel.loadLists() }
              }
          }
        }

        // Loading indicator for pagination
        if viewModel.isLoadingMorePosts {
          ProgressView()
            .padding()
            .frame(maxWidth: .infinity)
        }
      }
    }
  }

  @ViewBuilder
  private var starterPacksList: some View {
    if viewModel.isLoading && viewModel.starterPacks.isEmpty {
      ProgressView("Loading starter packs...")
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
    } else if viewModel.starterPacks.isEmpty {
      emptyContentView("No Starter Packs", "This user hasn't created any starter packs yet.")
    } else {
        ForEach(viewModel.starterPacks, id: \.uri) { pack in
          Button {
            path.append(NavigationDestination.starterPack(pack.uri))
          } label: {
            StarterPackRowView(pack: pack)
          }
          .applyListRowModifiers(id: pack.uri.uriString())

          // Load more when reaching the end
          if pack == viewModel.starterPacks.last && !viewModel.isLoadingMorePosts
            && viewModel.hasMoreStarterPacks
          {
            Color.clear.frame(height: 20)
              .onAppear {
                Task { await viewModel.loadStarterPacks() }
              }
          }
        }

        // Loading indicator for pagination
        if viewModel.isLoadingMorePosts && viewModel.hasMoreStarterPacks {
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
        .font(.system(size: 48))
        .foregroundColor(.secondary)

      Text(title)
        .font(.title3)
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

#Preview {
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
