import SwiftUI
import Petrel

struct BlockedPostView: View {
    let blockedPost: AppBskyFeedDefs.BlockedPost
    @Binding var path: NavigationPath
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                
                Text("Post from blocked user")
            }
            .padding(.bottom, 4)
            
            Text("@\(blockedPost.author.did)")
                .foregroundColor(.secondary)
            
            // Direct navigation - no abstraction!
            Button {
                path.append(NavigationDestination.profile(blockedPost.author.did.description))
            } label: {
                Text("View Profile")
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(8)
            }
            .padding(.top, 4)
        }
        .padding()
        .cornerRadius(12)
    }
}
