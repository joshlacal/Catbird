import SwiftUI
import Petrel

/// View for displaying a starter pack's details and profiles
struct StarterPackView: View {
    let uri: ATProtocolURI
    @State private var starterPack: AppBskyGraphDefs.StarterPackView?
    @State private var isLoading = true
    @State private var error: Error?
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    
    // Pagination state
    @State private var allProfiles: [AppBskyGraphDefs.ListItemView] = []
    @State private var cursor: String?
    @State private var isLoadingMore = false
    
    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if let error = error {
                errorView(error)
            } else if let pack = starterPack {
                packContentView(pack)
            } else {
                notFoundView
            }
        }
        .navigationTitle("Starter Pack")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
        .task {
            await fetchStarterPack()
        }
    }
    
    // Loading placeholder
    private var loadingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.large)
            
            Text("Loading starter pack...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // Error display
    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .appFont(size: 48)
                .foregroundColor(.orange)
            
            Text("Error loading starter pack")
                .appFont(AppTextRole.headline)
            
            Text(error.localizedDescription)
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button {
                Task {
                    isLoading = true
                    self.error = nil as Error?
                    await fetchStarterPack()
                }
            } label: {
                Text("Try Again")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.white)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // Not found state
    private var notFoundView: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle")
                .appFont(size: 48)
                .foregroundColor(.secondary)
            
            Text("Starter Pack Not Found")
                .appFont(AppTextRole.headline)
            
            Text("This starter pack might have been deleted or is unavailable.")
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button {
                path.removeLast()
            } label: {
                Text("Go Back")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.white)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // Main content view displaying the starter pack
    private func packContentView(_ pack: AppBskyGraphDefs.StarterPackView) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                // Header with creator info
                headerView(pack)
                
                // Description if available
                if case .knownType(let recordValue) = pack.record,
                   let starterpack = recordValue as? AppBskyGraphStarterpack,
                   let description = starterpack.description {
                    Text(description)
                        .appFont(AppTextRole.subheadline)
                        .padding(.horizontal)
                }
                
                Divider()
                
                // Stats
                statsView(pack)
                
                Divider()
                
                // Profiles - use paginated list instead of sample
                if !allProfiles.isEmpty {
                    profilesSection(allProfiles)
                }
                
                // Feed suggestions
                if let feeds = pack.feeds, !feeds.isEmpty {
                    feedsSection(feeds)
                }
                
                // Loading indicator for pagination
                if isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding()
                }
                
                Spacer(minLength: 40)
            }
            .padding(.vertical)
        }
    }
    
    // Header with pack creator info
    private func headerView(_ pack: AppBskyGraphDefs.StarterPackView) -> some View {
        HStack(spacing: 16) {
            // Creator avatar
            AsyncProfileImage(url: URL(string: pack.creator.avatar?.uriString() ?? ""), size: 60)
                .padding(.leading)
            
            // Creator info
            VStack(alignment: .leading, spacing: 4) {
                // Use name from record if available
                if case .knownType(let recordValue) = pack.record,
                   let starterpack = recordValue as? AppBskyGraphStarterpack {
                    Text(starterpack.name)
                        .appFont(AppTextRole.title3)
                        .fontWeight(.bold)
                } else {
                    Text("Starter Pack")
                        .appFont(AppTextRole.title3)
                        .fontWeight(.bold)
                }
                
                // Creator
                Text("Created by @\(pack.creator.handle)")
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    // Statistics about the pack
    private func statsView(_ pack: AppBskyGraphDefs.StarterPackView) -> some View {
        HStack(spacing: 24) {
            // Profile count - use actual list count, or loaded profiles count
            VStack {
                if let listItemCount = pack.list?.listItemCount {
                    Text("\(listItemCount)")
                        .appFont(AppTextRole.headline)
                } else {
                    Text("\(allProfiles.count)")
                        .appFont(AppTextRole.headline)
                }
                
                Text("Profiles")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
            
            // Feeds count
            VStack {
                Text("\(pack.feeds?.count ?? 0)")
                    .appFont(AppTextRole.headline)
                
                Text("Feeds")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
            
            // Weekly joins
            if let joinedWeekCount = pack.joinedWeekCount {
                VStack {
                    Text("\(joinedWeekCount)")
                        .appFont(AppTextRole.headline)
                    
                    Text("Joined this week")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // All-time joins
            if let joinedAllTimeCount = pack.joinedAllTimeCount {
                VStack {
                    Text("\(joinedAllTimeCount)")
                        .appFont(AppTextRole.headline)
                    
                    Text("All-time joins")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.systemGray6)
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    // Profiles section with pagination support
    private func profilesSection(_ profiles: [AppBskyGraphDefs.ListItemView]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggested Profiles")
                .appFont(AppTextRole.headline)
                .padding(.horizontal)
            
            VStack(spacing: 0) {
                ForEach(Array(profiles.enumerated()), id: \.element.uri) { index, item in
                    let subject = item.subject
                    
                    Button {
                        path.append(NavigationDestination.profile(subject.did.didString()))
                    } label: {
                        HStack(spacing: 12) {
                            AsyncProfileImage(url: URL(string: subject.avatar?.uriString() ?? ""), size: 44)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(subject.displayName ?? "@\(subject.handle)")
                                    .appFont(AppTextRole.headline)
                                    .foregroundColor(.primary)
                                
                                Text("@\(subject.handle)")
                                    .appFont(AppTextRole.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if let description = subject.description, !description.isEmpty {
                                    Text(description)
                                        .appFont(AppTextRole.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .appFont(AppTextRole.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        // Trigger pagination when approaching the end
                        if index == profiles.count - 3 {
                            Task {
                                await loadMoreProfiles()
                            }
                        }
                    }
                    
                    if item.uri.uriString() != profiles.last?.uri.uriString() {
                        Divider()
                            .padding(.leading, 56)
                    }
                    
                }
            }
            .background(Color.systemBackground)
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }
    
    // Feeds section
    private func feedsSection(_ feeds: [AppBskyFeedDefs.GeneratorView]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggested Feeds")
                .appFont(AppTextRole.headline)
                .padding(.horizontal)
            
            VStack(spacing: 0) {
                ForEach(feeds, id: \.uri) { feed in
                    Button {
                        path.append(NavigationDestination.feed(feed.uri))
                    } label: {
                        HStack(spacing: 12) {
                            // Feed avatar
                            if let avatar = feed.avatar {
                                AsyncImage(url: URL(string: avatar.uriString())) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Color.gray.opacity(0.2)
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(width: 44, height: 44)
                                    .overlay(
                                        Image(systemName: "rectangle.grid.1x2")
                                            .foregroundColor(.gray)
                                    )
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(feed.displayName)
                                    .appFont(AppTextRole.headline)
                                    .foregroundColor(.primary)
                                
                                Text("By @\(feed.creator.handle)")
                                    .appFont(AppTextRole.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if let description = feed.description, !description.isEmpty {
                                    Text(description)
                                        .appFont(AppTextRole.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .appFont(AppTextRole.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                    }
                    .buttonStyle(.plain)
                    
                    if feed.uri.uriString() != feeds.last?.uri.uriString() {
                        Divider()
                            .padding(.leading, 56)
                    }
                }
            }
            .background(Color.systemBackground)
            .cornerRadius(12)
            .padding(.horizontal)
        }
    }
    
    // Fetch starter pack data
    private func fetchStarterPack() async {
        guard let client = appState.atProtoClient else {
            error = NSError(domain: "StarterPackView", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not logged in"])
            isLoading = false
            return
        }
        
        do {
            let input = AppBskyGraphGetStarterPack.Parameters(starterPack: uri)
            let response = try await client.app.bsky.graph.getStarterPack(input: input)
            
            if let packData = response.data {
                self.starterPack = packData.starterPack
                
                // Fetch full list with pagination if list exists
                if let listUri = packData.starterPack.list?.uri {
                    await loadProfileList(client: client, listUri: listUri, cursor: nil)
                }
            } else {
                self.error = NSError(domain: "StarterPackView", code: 0, userInfo: [NSLocalizedDescriptionKey: "No data returned"])
            }
        } catch {
            self.error = error
        }
        
        isLoading = false
    }
    
    // Load profile list with pagination
    private func loadProfileList(client: ATProtoClient, listUri: ATProtocolURI, cursor: String?) async {
        do {
            let input = AppBskyGraphGetList.Parameters(
                list: listUri,
                limit: 30,
                cursor: cursor
            )
            let response = try await client.app.bsky.graph.getList(input: input)
            
            if let data = response.data {
                // Append new profiles to the list
                allProfiles.append(contentsOf: data.items)
                self.cursor = data.cursor
            }
        } catch {
            // Log error but don't show to user - initial load already succeeded
            print("Error loading profile list: \(error)")
        }
    }
    
    // Load more profiles when scrolling near the end
    private func loadMoreProfiles() async {
        guard let pack = starterPack,
              let listUri = pack.list?.uri,
              let currentCursor = cursor,
              !isLoadingMore,
              let client = appState.atProtoClient else {
            return
        }
        
        isLoadingMore = true
        await loadProfileList(client: client, listUri: listUri, cursor: currentCursor)
        isLoadingMore = false
    }
}
