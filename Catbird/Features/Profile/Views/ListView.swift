import SwiftUI
import Petrel
import NukeUI
import OSLog

struct ListView: View {
    let listURI: ATProtocolURI
    @Binding var path: NavigationPath
    @State private var listData: AppBskyGraphDefs.ListView?
    @State private var listItems: [AppBskyGraphDefs.ListItemView] = []
    @State private var isLoading = true
    @State private var cursor: String?
    @State private var error: String?
    @Environment(AppState.self) private var appState
    
    private let logger = Logger(subsystem: "blue.catbird", category: "ListView")
    
    var body: some View {
        Group {
            if isLoading && listData == nil {
                ProgressView("Loading list...")
                    .scaleEffect(1.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                        .font(.title2)
                    Text("Failed to load list")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        Task { await loadList() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let list = listData {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ListHeaderView(list: list)
                            .padding()
                        
                        Divider()
                        
                        ForEach(listItems, id: \.uri) { item in
                            Button {
                                path.append(NavigationDestination.profile(item.subject.did.didString()))
                            } label: {
                                ListItemRow(item: item)
                            }
                            .buttonStyle(.plain)
                            
                            Divider()
                        }
                        
                        if let cursor = cursor, !isLoading {
                            Button("Load More") {
                                Task {
                                    await loadMoreItems()
                                }
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .padding()
                        } else if isLoading && !listItems.isEmpty {
                            ProgressView("Loading more...")
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                    }
                }
                .navigationTitle(list.name)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            } else {
                Text("Could not load list")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await loadList()
        }
    }
    
    private func loadList() async {
        guard let client = appState.atProtoClient else {
            await MainActor.run {
                error = "Not connected to AT Protocol"
                isLoading = false
            }
            return
        }
        
        await MainActor.run {
            isLoading = true
            error = nil
        }
        
        do {
            logger.info("Loading list: \(listURI.uriString())")
            
            // First, get the list details
            let listParams = AppBskyGraphGetList.Parameters(
                list: listURI,
                limit: 50,
                cursor: nil
            )
            
            let (responseCode, response) = try await client.app.bsky.graph.getList(input: listParams)
            
            await MainActor.run {
                guard responseCode >= 200 && responseCode < 300, let response = response else {
                    error = "Failed to load list (HTTP \(responseCode))"
                    isLoading = false
                    logger.error("Failed to load list: HTTP \(responseCode)")
                    return
                }
                
                listData = response.list
                listItems = response.items
                cursor = response.cursor
                isLoading = false
                
                logger.info("Loaded list '\(response.list.name)' with \(response.items.count) items")
            }
            
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isLoading = false
                logger.error("Error loading list: \(error.localizedDescription)")
            }
        }
    }
    
    private func loadMoreItems() async {
        guard let client = appState.atProtoClient,
              let currentCursor = cursor,
              !isLoading else { return }
        
        await MainActor.run {
            isLoading = true
        }
        
        do {
            logger.info("Loading more list items with cursor: \(currentCursor)")
            
            let listParams = AppBskyGraphGetList.Parameters(
                list: listURI,
                limit: 50,
                cursor: currentCursor
            )
            
            let (responseCode, response) = try await client.app.bsky.graph.getList(input: listParams)
            
            await MainActor.run {
                guard responseCode >= 200 && responseCode < 300, let response = response else {
                    error = "Failed to load more items (HTTP \(responseCode))"
                    isLoading = false
                    logger.error("Failed to load more items: HTTP \(responseCode)")
                    return
                }
                
                listItems.append(contentsOf: response.items)
                cursor = response.cursor
                isLoading = false
                
                logger.info("Loaded \(response.items.count) more items, total: \(listItems.count)")
            }
            
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isLoading = false
                logger.error("Error loading more items: \(error.localizedDescription)")
            }
        }
    }
}

struct ListHeaderView: View {
    let list: AppBskyGraphDefs.ListView
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // List avatar
                if let avatarURL = list.avatar?.uriString() {
                    LazyImage(url: URL(string: avatarURL)) { state in
                        if let image = state.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.2))
                        }
                    }
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: 80, height: 80)
                        .overlay(
                            Image(systemName: "list.bullet")
                                .foregroundColor(.accentColor)
                                .appFont(size: 32)

                        )
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(list.name)
                        .appFont(AppTextRole.title2)
                        .fontWeight(.bold)
                    
                    Text("By @\(list.creator.handle)")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.secondary)
                    
                    if let itemCount = list.listItemCount {
                        Text("\(itemCount) items")
                            .appFont(AppTextRole.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if let description = list.description, !description.isEmpty {
                Text(description)
                                    .appFont(AppTextRole.body)
                    .padding(.top, 4)
            }
        }
    }
}

struct ListItemRow: View {
    let item: AppBskyGraphDefs.ListItemView
    
    var body: some View {
        HStack(spacing: 12) {
            // Profile avatar
            if let avatarURL = item.subject.avatar?.uriString() {
                LazyImage(url: URL(string: avatarURL)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Circle()
                            .fill(Color.secondary.opacity(0.2))
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundColor(.secondary)
                    )
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.subject.displayName ?? item.subject.handle.description)
                    .appFont(AppTextRole.headline)
                
                Text("@\(item.subject.handle)")
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
    }
}

// Preview with safer URI creation
// #Preview {
//    NavigationStack {
//        ListView(
//            listURI: ATProtocolURI(from: "at://did:example/app.bsky.graph.list/123")!,
//            path: .constant(NavigationPath())
//        )
//    }
// }
