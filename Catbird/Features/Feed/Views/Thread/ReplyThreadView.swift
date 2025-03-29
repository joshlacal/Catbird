import SwiftUI
import Petrel
import NukeUI

struct ReplyThreadView: View {
    let reply: AppBskyFeedDefs.ReplyRef
    @Binding var path: NavigationPath
    
    // Extract the actual post from the parent union
    private var parentPost: AppBskyFeedDefs.PostView? {
        if case .appBskyFeedDefsPostView(let post) = reply.parent {
            return post
        }
        return nil
    }
    
    // Extract blocked state if relevant
    private var isParentBlocked: Bool {
        if case .appBskyFeedDefsBlockedPost = reply.parent {
            return true
        }
        return false
    }
    
    var body: some View {
        if let parent = parentPost {
            VStack(alignment: .leading, spacing: 0) {
                // Reply connection line
                HStack {
                    replyLine
                    Spacer()
                }
                .frame(height: 20)
                
                // Parent post preview
                Button {
                    path.append(NavigationDestination.post(parent.uri))
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        // Author avatar
                        if let avatarURL = parent.author.finalAvatarURL() {
                            LazyImage(url: avatarURL) { state in
                                if let image = state.image {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color.gray.opacity(0.2)
                                }
                            }
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            // Author info
                            HStack {
                                Text(parent.author.displayName ?? parent.author.handle.description)
                                    .font(.subheadline.weight(.medium))
                                Text("@\(parent.author.handle)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            
                            // Post content preview
                            if case let .knownType(record) = parent.record,
                               let parentPost = record as? AppBskyFeedPost {
                                Text(parentPost.text)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                
                // Reply indicator arrow
                HStack {
                    replyArrow
                    Spacer()
                }
                .frame(height: 16)
            }
        } else if isParentBlocked {
            Text("Content from blocked user")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding()
        }
    }
    
    private var replyLine: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.3))
            .frame(width: 2)
            .padding(.leading, 24) // Align with avatar
    }
    
    private var replyArrow: some View {
        Image(systemName: "arrow.turn.down.left")
            .foregroundStyle(.secondary)
            .padding(.leading, 16)
    }
}
