// import SwiftUI
// import Petrel
//
// struct ReplyView: View {
//    let replyWrapper: ReplyWrapper
//    let opAuthorID: String
//    @Binding var path: NavigationPath
//    let appState: AppState
//    
//    var body: some View {
//        switch replyWrapper.reply {
//        case .appBskyFeedDefsThreadViewPost(let replyPost):
//            VStack(alignment: .leading, spacing: 0) {
//                // The reply post itself - mark as parent if we're showing a reply beneath it
//                PostView(
//                    post: replyPost.post,
//                    grandparentAuthor: nil,
//                    isParentPost: replyPost.replies?.isEmpty == false,
//                    isSelectable: false,
//                    path: $path,
//                    appState: appState
//                )
//                .contentShape(Rectangle())
//                .onTapGesture {
//                    path.append(NavigationDestination.post(replyPost.post.uri))
//                }
//                
//                // Show just one reply to create a continuous thread feeling
//                if let replies = replyPost.replies, !replies.isEmpty {
//                    // Get the most relevant reply to show
//                    let nestedReplyToShow = selectMostRelevantReply(replies, opAuthorID: opAuthorID)
//                    
//                    switch nestedReplyToShow {
//                    case .appBskyFeedDefsThreadViewPost(let nestedPost):
//                        PostView(
//                            post: nestedPost.post,
//                            grandparentAuthor: nil,
//                            isParentPost: false,
//                            isSelectable: false,
//                            path: $path,
//                            appState: appState
//                        )
//                        .contentShape(Rectangle())
//                        .onTapGesture {
//                            path.append(NavigationDestination.post(nestedPost.post.uri))
//                        }
//                    default:
//                        EmptyView()
//                    }
//                }
//            }
//            .padding(.vertical, 3)
//            .frame(maxWidth: 550, alignment: .leading)
//            
//        case .appBskyFeedDefsNotFoundPost(let notFoundPost):
//            Text("Reply not found: \(notFoundPost.uri.uriString())")
//                .foregroundColor(.red)
//                
//        case .appBskyFeedDefsBlockedPost(let blocked):
//            BlockedPostView(blockedPost: blocked, path: $path)
//                
//        case .unexpected(let unexpected):
//            Text("Unexpected reply type: \(unexpected.textRepresentation)")
//                .foregroundColor(.orange)
//                
//        case .pending:
//            EmptyView()
//        
//        case .appBskyFeedDefsDeepSkyBlockedPost(let blockedPost):
//            Text("This reply was blocked: \(blockedPost.uri)")
//                .foregroundColor(.red)
//        }
//    }
//    
//    // Helper function to select the most relevant nested reply to show
//    private func selectMostRelevantReply(
//        _ replies: [AppBskyFeedDefs.ThreadViewPostRepliesUnion], opAuthorID: String
//    ) -> AppBskyFeedDefs.ThreadViewPostRepliesUnion {
//        // Priority: 1) From OP, 2) Has replies itself, 3) Most recent
//        
//        // Check for replies from OP
//        if let opReply = replies.first(where: { reply in
//            if case .appBskyFeedDefsThreadViewPost(let post) = reply {
//                return post.post.author.did.didString() == opAuthorID
//            }
//            return false
//        }) {
//            return opReply
//        }
//        
//        // Check for replies that have their own replies
//        if let threadReply = replies.first(where: { reply in
//            if case .appBskyFeedDefsThreadViewPost(let post) = reply {
//                return !(post.replies?.isEmpty ?? true)
//            }
//            return false
//        }) {
//            return threadReply
//        }
//        
//        // Default to first reply
//        return replies.first!
//    }
// }
