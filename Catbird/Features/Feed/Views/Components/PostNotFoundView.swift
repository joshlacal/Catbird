import SwiftUI
import Petrel
import OSLog

struct PostNotFoundView: View {
    let uri: ATProtocolURI?
    let reason: PostNotFoundReason
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    
    @State private var isRetrying = false
    @State private var fetchedPost: AppBskyFeedDefs.PostView?
    @State private var showingFetchedContent = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "PostNotFoundView")
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showingFetchedContent, let post = fetchedPost {
                // Show the successfully fetched post
                PostView(
                    post: post,
                    grandparentAuthor: nil,
                    isParentPost: false,
                    isSelectable: true,
                    path: $path,
                    appState: appState
                )
                .overlay(alignment: .topTrailing) {
                    Button("Hide") {
                        showingFetchedContent = false
                    }
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding()
                }
            } else {
                notFoundCard
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showingFetchedContent)
    }
    
    private var notFoundCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryMessage)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    
                    if let secondaryMessage = secondaryMessage {
                        Text(secondaryMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
            }
            
            // URI info if available
            if let uri = uri {
                uriInfoSection(uri: uri)
            }
            
            // Action buttons
            actionButtons
        }
        .padding(16)
        .background(Color.systemGroupedBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(iconColor.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private func uriInfoSection(uri: ATProtocolURI) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Post Reference")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            Text(uri.uriString())
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.systemFill)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
    
    private var actionButtons: some View {
        HStack(spacing: 12) {
            if shouldShowRetryButton {
                Button(action: retryFetch) {
                    HStack(spacing: 6) {
                        if isRetrying {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        Text("Retry")
                            .font(.callout)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.2))
                    .foregroundStyle(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(isRetrying)
            }
            
            if shouldShowReportButton {
                Button(action: reportBrokenLink) {
                    HStack(spacing: 6) {
                        Image(systemName: "flag")
                            .font(.caption)
                        Text("Report")
                            .font(.callout)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.2))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            
            Spacer()
        }
    }
}

// MARK: - Computed Properties
extension PostNotFoundView {
    private var primaryMessage: String {
        switch reason {
        case .deleted:
            return "Post deleted"
        case .notFound:
            return "Post not found"
        case .networkError:
            return "Could not load post"
        case .parseError:
            return "Post format error"
        case .permissionDenied:
            return "Access denied"
        case .temporarilyUnavailable:
            return "Temporarily unavailable"
        }
    }
    
    private var secondaryMessage: String? {
        switch reason {
        case .deleted:
            return "This post has been deleted by the author"
        case .notFound:
            return "This post may have been moved or removed"
        case .networkError:
            return "Check your connection and try again"
        case .parseError:
            return "The post content could not be processed"
        case .permissionDenied:
            return "You don't have permission to view this post"
        case .temporarilyUnavailable:
            return "The post is currently unavailable"
        }
    }
    
    private var iconName: String {
        switch reason {
        case .deleted:
            return "trash"
        case .notFound:
            return "questionmark.circle"
        case .networkError:
            return "wifi.exclamationmark"
        case .parseError:
            return "doc.text.fill.viewfinder"
        case .permissionDenied:
            return "lock"
        case .temporarilyUnavailable:
            return "clock.circle"
        }
    }
    
    private var iconColor: Color {
        switch reason {
        case .deleted:
            return .red
        case .notFound:
            return .gray
        case .networkError:
            return .orange
        case .parseError:
            return .yellow
        case .permissionDenied:
            return .gray
        case .temporarilyUnavailable:
            return .blue
        }
    }
    
    private var shouldShowRetryButton: Bool {
        switch reason {
        case .networkError, .temporarilyUnavailable, .notFound:
            return true
        case .deleted, .parseError, .permissionDenied:
            return false
        }
    }
    
    private var shouldShowReportButton: Bool {
        switch reason {
        case .parseError, .notFound:
            return true
        case .deleted, .networkError, .permissionDenied, .temporarilyUnavailable:
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
                        showingFetchedContent = true
                        isRetrying = false
                    }
                    logger.debug("Successfully fetched post on retry")
                } else {
                    await MainActor.run {
                        isRetrying = false
                    }
                    logger.warning("Post still not found on retry")
                }
            } catch {
                await MainActor.run {
                    isRetrying = false
                }
                logger.error("Retry fetch failed: \(error)")
            }
        }
    }
    
    private func reportBrokenLink() {
        logger.debug("User reported broken post link")
        // Could implement reporting functionality here
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
