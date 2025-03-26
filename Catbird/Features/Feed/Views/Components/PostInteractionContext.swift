import SwiftUI
import Petrel

struct PostInteractionContext: View {
    let post: AppBskyFeedDefs.PostView
    @Environment(AppState.self) private var appState
    
    private var isLiked: Bool {
        post.viewer?.like != nil
    }
    
    private var isReposted: Bool {
        post.viewer?.repost != nil
    }
    
    var body: some View {
        HStack(spacing: 0) {
            Label {
                Text("\(post.likeCount ?? 0)")
            } icon: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .foregroundStyle(isLiked ? .red : .secondary)
            }
            
            Label {
                Text("\(post.repostCount ?? 0)")
            } icon: {
                Image(systemName: "arrow.2.squarepath")
                    .foregroundStyle(isReposted ? .green : .secondary)
            }
            
            Label {
                Text("\(post.replyCount ?? 0)")
            } icon: {
                Image(systemName: "bubble.right")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }
}
