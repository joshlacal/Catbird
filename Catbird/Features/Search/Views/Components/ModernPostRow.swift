import SwiftUI
import Petrel
import NukeUI

struct ModernPostRow: View {
    let post: AppBskyFeedDefs.PostView
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    
    var body: some View {
        PostView(post: post, grandparentAuthor: nil, isParentPost: false, isSelectable: false, path: $path, appState: appState)
    }
}

struct ProfileImageView: View {
    let url: URL?
    let size: CGFloat
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: size, height: size)
            
            if let url = url {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            }
        }
    }
}

struct StatLabel: View {
    let count: Int
    let iconName: String
    
    var body: some View {
        Label {
            Text("\(count)")
        } icon: {
            Image(systemName: iconName)
                .font(.caption)
        }
    }
}

struct PostEmbedPreview: View {
    let embed: AppBskyFeedDefs.PostViewEmbedUnion?
    
    var body: some View {
        if let embed = embed {
            switch embed {
            case .appBskyEmbedImagesView:
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 120)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    )
                
            case .appBskyEmbedExternalView:
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: 80)
                    .overlay(
                        Image(systemName: "link")
                            .foregroundColor(.secondary)
                    )
                
            case .appBskyEmbedRecordView:
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))
                    .frame(height: 80)
                    .overlay(
                        Image(systemName: "quote.bubble")
                            .foregroundColor(.secondary)
                    )
                
            default:
                EmptyView()
            }
        } else {
            EmptyView()
        }
    }
}

// Add a preview
#Preview {
    // Since we don't have an actual PostView to preview, we'll just show a placeholder
    VStack {
        Text("Post Row Preview")
            .font(.headline)
            .padding()
        
        Text("This is a preview placeholder since we need real data to show the actual ModernPostRow")
            .padding()
    }
}
