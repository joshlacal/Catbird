import SwiftUI
import Petrel

/// A view that displays a thread slice with multiple posts in a thread-like format
// struct ThreadSliceView: View {
//    let slice: FeedSlice
//    let path: NavigationPath
//    let appState: AppState
//    
//    var body: some View {
//        VStack(alignment: .leading, spacing: 4) {
//            ForEach(Array(slice.items.enumerated()), id: \.element.id) { index, item in
//                ThreadSliceItemView(
//                    item: item,
//                    isLast: index == slice.items.count - 1,
//                    path: path,
//                    appState: appState
//                )
//                
//                if index < slice.items.count - 1 {
//                    ThreadSeparatorView()
//                }
//            }
//        }
//        .background(Color.dynamicBackground(appState.themeManager))
//    }
// }

/// Individual item within a thread slice
struct ThreadSliceItemView: View {
    let item: FeedSliceItem
    let isLast: Bool
    let path: NavigationPath
    let appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Author info
            HStack {
                AsyncProfileImage(
                    url: item.post.author.avatar?.url,
                    size: 24
                )
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.post.author.displayName ?? item.post.author.handle.description)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    Text("@\(item.post.author.handle.description)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Timestamp
                Text(item.record.createdAt.date.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // Post content
            Text(item.record.text)
                .font(.callout)
                .foregroundColor(.primary)
                .padding(.leading, 32)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

#Preview {
    // Preview would need mock data
    EmptyView()
}
