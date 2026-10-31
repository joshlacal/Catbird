import SwiftUI
import Petrel
import OSLog

/// The quiet row shown in place of a post that couldn't be loaded.
///
/// Feed rows, thread rows and post views all hold this view as one branch of
/// their bodies, and Debug builds give every branch its own stack slot, so it
/// keeps the URI and any retried post boxed instead of inline.
struct PostNotFoundView: View {
    private let uri: EquatableBox<ATProtocolURI>?
    let reason: PostNotFoundReason
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    
    @State private var isRetrying = false
    @State private var retryFailed = false
    @State private var fetchedPost: EquatableBox<AppBskyFeedDefs.PostView>?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "PostNotFoundView")

    init(uri: ATProtocolURI?, reason: PostNotFoundReason, path: Binding<NavigationPath>) {
        self.uri = uri.map { EquatableBox($0) }
        self.reason = reason
        self._path = path
    }

    init(postURI: ATProtocolURI, postCID: CID? = nil, didTapAccount: ((DID) -> Void)? = nil) {
        self.uri = EquatableBox(postURI)
        self.reason = .notFound
        self._path = .constant(NavigationPath())
    }
    
    var body: some View {
        if let fetchedPost {
            // A transient failure that cleared on retry shows the post itself.
            PostNotFoundRetriedPost(post: fetchedPost, path: $path)
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
                logger.debug("Retrying fetch for post: \(uri.value)")
                
                let response = try await client.app.bsky.feed.getPosts(
                    input: AppBskyFeedGetPosts.Parameters(uris: [uri.value])
                )
                
                if let post = response.1?.posts.first {
                    await MainActor.run {
                        fetchedPost = EquatableBox(post)
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

// MARK: - Retried Post

/// The post a successful retry fetched. A separate view, so the not-found
/// row's body type carries only the box rather than the post view built from it.
private struct PostNotFoundRetriedPost: View {
    let post: EquatableBox<AppBskyFeedDefs.PostView>
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState

    var body: some View {
        makePostView()
    }

    /// Builds the post view in its own short-lived frame, so the copy of the
    /// boxed post that `PostView.init` takes never gets a slot in `body`'s frame.
    private func makePostView() -> PostView {
        PostView(
            post: post.value,
            grandparentAuthor: nil,
            isParentPost: false,
            isSelectable: true,
            path: $path,
            appState: appState
        )
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
