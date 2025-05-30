import SwiftUI
import Petrel
import NukeUI

struct ListView: View {
    let listURI: ATProtocolURI
    @Binding var path: NavigationPath
    @State private var listData: AppBskyGraphDefs.ListView?
    @State private var listItems: [AppBskyGraphDefs.ListItemView] = []
    @State private var isLoading = true
    @State private var cursor: String?
    
    var body: some View {
        Group {
            if isLoading && listData == nil {
                ProgressView()
                    .scaleEffect(1.5)
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
                        
                        if cursor != nil {
                            Button("Load More") {
                                Task {
                                    await loadMoreItems()
                                }
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                    }
                }
                .navigationTitle(list.name)
                .navigationBarTitleDisplayMode(.inline)
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
        // This would fetch the list details and initial items
        isLoading = false
        
        // TODO: load list data
    }
    
    private func loadMoreItems() async {
        // This would load more list items with pagination
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
                                .font(.system(size: 32))
                        )
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(list.name)
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("By @\(list.creator.handle)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if let itemCount = list.listItemCount {
                        Text("\(itemCount) items")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if let description = list.description, !description.isEmpty {
                Text(description)
                    .font(.body)
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
                    .font(.headline)
                
                Text("@\(item.subject.handle)")
                    .font(.subheadline)
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
