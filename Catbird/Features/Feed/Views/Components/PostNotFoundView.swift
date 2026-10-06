import SwiftUI
import Petrel
import OSLog

struct PostNotFoundView: View {
    let uri: ATProtocolURI?
    let reason: PostNotFoundReason
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    
    @State private var isRetrying = false
    @State private var retryFailed = false
    @State private var fetchedPost: AppBskyFeedDefs.PostView?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "PostNotFoundView")

    init(uri: ATProtocolURI?, reason: PostNotFoundReason, path: Binding<NavigationPath>) {
        self.uri = uri
        self.reason = reason
        self._path = path
    }

    init(postURI: ATProtocolURI, postCID: CID? = nil, didTapAccount: ((DID) -> Void)? = nil) {
        self.uri = postURI
        self.reason = .notFound
        self._path = .constant(NavigationPath())
    }
    
    var body: some View {
        if let post = fetchedPost {
            // A transient failure that cleared on retry shows the post itself.
            PostView(
                post: post,
                grandparentAuthor: nil,
                isParentPost: false,
                isSelectable: true,
                path: $path,
                appState: appState
            )
        } else {
            unavailableRow
        }
    }
    
    /// A compact, quiet row in place of the post.
    private var unavailableRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(Color.secondary)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryMessage)
                    .appFont(AppTextRole.subheadline)
                    .foregroundStyle(Color.secondary)
                
                if let secondaryMessage = currentSecondaryMessage {
                    Text(secondaryMessage)
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(Color.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            
            Spacer(minLength: 0)
            
            if shouldShowRetryButton {
                retryButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.systemFill.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    
    private var retryButton: some View {
        Button(action: retryFetch) {
            if isRetrying {
                ProgressView()
            } else {
                Text("Try Again")
                    .appFont(AppTextRole.subheadline)
            }
        }
        .buttonStyle(.borderless)
        .disabled(isRetrying)
    }
}

// MARK: - Computed Properties
extension PostNotFoundView {
    private var primaryMessage: String {
        switch reason {
        case .deleted, .notFound:
            return "Deleted post"
        case .networkError:
            return "Couldn’t load this post"
        case .parseError:
            return "This post can’t be shown"
        case .permissionDenied:
            return "Post unavailable"
        case .temporarilyUnavailable:
            return "Post temporarily unavailable"
        }
    }
    
    private var currentSecondaryMessage: String? {
        if retryFailed {
            return "Still unavailable. Try again later."
        }
        switch reason {
        case .deleted, .notFound, .parseError:
            return nil
        case .networkError:
            return "Check your connection and try again."
        case .permissionDenied:
            return "You don’t have permission to view this post."
        case .temporarilyUnavailable:
            return "Try again in a moment."
        }
    }
    
    private var iconName: String {
        switch reason {
        case .deleted, .notFound:
            return "trash"
        case .networkError:
            return "wifi.exclamationmark"
        case .parseError:
            return "exclamationmark.bubble"
        case .permissionDenied:
            return "lock"
        case .temporarilyUnavailable:
            return "clock"
        }
    }
    
    /// Retry only helps when the failure was transient.
    private var shouldShowRetryButton: Bool {
        guard uri != nil else { return false }
        switch reason {
        case .networkError, .temporarilyUnavailable:
            return true
        case .deleted, .notFound, .parseError, .permissionDenied:
            return false
        }
    }
}

// MARK: - Actions
extension PostNotFoundView {
    private func retryFetch() {
        guard !isRetrying, let uri = uri, let client = appState.atProtoClient else { return }
        
        isRetrying = true
        
        Task {
            do {
                logger.debug("Retrying fetch for post: \(uri)")
                
                let response = try await client.app.bsky.feed.getPosts(
                    input: AppBskyFeedGetPosts.Parameters(uris: [uri])
                )
                
                if let post = response.1?.posts.first {
                    await MainActor.run {
                        fetchedPost = post
                        isRetrying = false
                    }
                    logger.debug("Successfully fetched post on retry")
                } else {
                    await MainActor.run {
                        retryFailed = true
                        isRetrying = false
                    }
                    logger.warning("Post still not found on retry")
                }
            } catch {
                await MainActor.run {
                    retryFailed = true
                    isRetrying = false
                }
                logger.error("Retry fetch failed: \(error)")
            }
        }
    }
}

// MARK: - Supporting Types
enum PostNotFoundReason {
    case deleted                // Post was deleted
    case notFound              // Post doesn't exist or URI is invalid
    case networkError          // Network connectivity issue
    case parseError            // Post data could not be parsed
    case permissionDenied      // Access restricted
    case temporarilyUnavailable // Server issues, rate limiting, etc.
}

#Preview("PostNotFoundView") {
  PostNotFoundView(uri: nil, reason: .deleted, path: .constant(NavigationPath()))
    .previewWithAuthenticatedState()
}
