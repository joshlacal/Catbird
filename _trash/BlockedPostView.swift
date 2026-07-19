import SwiftUI
import Petrel
import OSLog

struct BlockedPostView: View {
    let blockedPost: AppBskyFeedDefs.BlockedPost
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    
    @State private var isShowingContent = false
    @State private var fetchedPost: AppBskyFeedDefs.PostView?
    @State private var isLoading = false
    @State private var showingProfile = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "BlockedPostView")
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isShowingContent, let post = fetchedPost {
                // Show the actual post content
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
                        isShowingContent = false
                    }
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding()
                }
            } else {
                blockedContentCard
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isShowingContent)
    }
    
    private var blockedContentCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with icon and primary message
            HStack(spacing: 10) {
                blockIcon
                
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
            
            // Author info section
            authorInfoSection
            
            // Action buttons
            actionButtonsSection
        }
        .padding(16)
        .background(blockCardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(blockBorderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var blockIcon: some View {
        Image(systemName: blockIconName)
            .font(.title2)
            .foregroundStyle(blockIconColor)
            .frame(width: 24, height: 24)
    }
    
    private var authorInfoSection: some View {
        HStack(spacing: 8) {
            // Placeholder avatar
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(blockedPost.author.did.didString())
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                
                if let handle = extractHandle(from: blockedPost.author.did.didString()) {
                    Text("@\(handle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 4)
    }
    
    private var actionButtonsSection: some View {
        HStack(spacing: 12) {
            // Primary action button
            Button(action: primaryAction) {
                HStack(spacing: 6) {
                    Image(systemName: primaryActionIcon)
                        .font(.caption)
                    Text(primaryActionLabel)
                        .font(.callout)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(primaryActionBackground)
                .foregroundStyle(primaryActionForeground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(isLoading)
            
            // Secondary actions
            HStack(spacing: 8) {
                if shouldShowProfileButton {
                    Button(action: viewProfile) {
                        Image(systemName: "person.circle")
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                }
                
                if shouldShowFetchButton {
                    Button(action: fetchContent) {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "eye")
                                .font(.callout)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .disabled(isLoading)
                }
            }
            
            Spacer()
        }
    }
}

// MARK: - Computed Properties
extension BlockedPostView {
    private var blockingRelationship: BlockingRelationship {
        guard let viewer = blockedPost.author.viewer else {
            return .unknown
        }
        
        let iBlockedThem = viewer.blocking != nil
        let theyBlockedMe = viewer.blockedBy == true
        
        if iBlockedThem && theyBlockedMe {
            return .mutual
        } else if iBlockedThem {
            return .iBlockedThem
        } else if theyBlockedMe {
            return .theyBlockedMe
        } else {
            return .listBased // Likely blocked via moderation list
        }
    }
    
    private var primaryMessage: String {
        switch blockingRelationship {
        case .iBlockedThem:
            return "Post from blocked user"
        case .theyBlockedMe:
            return "Post unavailable"
        case .mutual:
            return "Post in blocked thread"
        case .listBased:
            return "Post from moderated user"
        case .unknown:
            return "Post unavailable"
        }
    }
    
    private var secondaryMessage: String? {
        switch blockingRelationship {
        case .iBlockedThem:
            return "You blocked this user"
        case .theyBlockedMe:
            return "This user has restricted their content"
        case .mutual:
            return "Mutual blocking detected"
        case .listBased:
            return "Blocked via moderation list"
        case .unknown:
            return nil
        }
    }
    
    private var blockIconName: String {
        switch blockingRelationship {
        case .iBlockedThem:
            return "hand.raised.fill"
        case .theyBlockedMe:
            return "lock.fill"
        case .mutual:
            return "hand.raised.slash.fill"
        case .listBased:
            return "list.bullet.clipboard.fill"
        case .unknown:
            return "exclamationmark.triangle.fill"
        }
    }
    
    private var blockIconColor: Color {
        switch blockingRelationship {
        case .iBlockedThem:
            return .orange
        case .theyBlockedMe:
            return .gray
        case .mutual:
            return .red
        case .listBased:
            return .blue
        case .unknown:
            return .yellow
        }
    }
    
    private var blockCardBackground: Color {
        Color.systemGroupedBackground
    }
    
    private var blockBorderColor: Color {
        blockIconColor.opacity(0.3)
    }
    
    private var primaryActionLabel: String {
        switch blockingRelationship {
        case .iBlockedThem:
            return "Unblock"
        case .theyBlockedMe:
            return "Unavailable"
        case .mutual:
            return "Show Anyway"
        case .listBased:
            return "More Info"
        case .unknown:
            return "Details"
        }
    }
    
    private var primaryActionIcon: String {
        switch blockingRelationship {
        case .iBlockedThem:
            return "hand.raised.slash"
        case .theyBlockedMe:
            return "lock"
        case .mutual:
            return "eye"
        case .listBased:
            return "info.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }
    
    private var primaryActionBackground: Color {
        switch blockingRelationship {
        case .iBlockedThem:
            return .orange.opacity(0.2)
        case .theyBlockedMe:
            return .gray.opacity(0.2)
        case .mutual:
            return .blue.opacity(0.2)
        case .listBased:
            return .blue.opacity(0.2)
        case .unknown:
            return .gray.opacity(0.2)
        }
    }
    
    private var primaryActionForeground: Color {
        switch blockingRelationship {
        case .iBlockedThem:
            return .orange
        case .theyBlockedMe:
            return .gray
        case .mutual:
            return .blue
        case .listBased:
            return .blue
        case .unknown:
            return .gray
        }
    }
    
    private var shouldShowProfileButton: Bool {
        // Allow profile viewing for users I blocked or list-based blocks
        blockingRelationship == .iBlockedThem || blockingRelationship == .listBased
    }
    
    private var shouldShowFetchButton: Bool {
        // Allow content fetching for my own blocks or mutual blocks in threads
        blockingRelationship == .iBlockedThem || blockingRelationship == .mutual
    }
}

// MARK: - Actions
extension BlockedPostView {
    private func primaryAction() {
        switch blockingRelationship {
        case .iBlockedThem:
            unblockUser()
        case .mutual:
            fetchContent()
        case .listBased:
            showMoreInfo()
        default:
            break
        }
    }
    
    private func unblockUser() {
        Task {
            do {
                try await appState.unblock(did: blockedPost.author.did.didString())
                logger.info("Successfully unblocked user: \(blockedPost.author.did.didString())")
            } catch {
                logger.error("Failed to unblock user: \(error)")
            }
        }
    }
    
    private func fetchContent() {
        guard !isLoading, let client = appState.atProtoClient else { return }
        
        isLoading = true
        
        Task {
            do {
                // Attempt to fetch the post directly
                logger.debug("Attempting to fetch blocked post: \(blockedPost.uri)")
                
                // Try to fetch the post via the posts endpoint
                let response = try await client.app.bsky.feed.getPosts(
                    input: AppBskyFeedGetPosts.Parameters(uris: [blockedPost.uri])
                )
                
                if let post = response.1?.posts.first {
                    await MainActor.run {
                        fetchedPost = post
                        isShowingContent = true
                        isLoading = false
                    }
                    logger.debug("Successfully fetched blocked post content")
                } else {
                    await MainActor.run {
                        isLoading = false
                    }
                    logger.warning("No post content returned for blocked post")
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                }
                logger.error("Failed to fetch blocked post: \(error)")
            }
        }
    }
    
    private func viewProfile() {
        path.append(NavigationDestination.profile(blockedPost.author.did.didString()))
    }
    
    private func showMoreInfo() {
        // Could show a sheet with more details about the moderation action
        logger.debug("Show more info for list-based block")
    }
    
    private func extractHandle(from did: String) -> String? {
        // Extract handle from DID if it contains one, or return a simplified version
        if did.contains("did:plc:") {
            return String(did.suffix(8)) // Show last 8 characters for brevity
        }
        return nil
    }
}

// MARK: - Supporting Types
private enum BlockingRelationship {
    case iBlockedThem      // User blocked the author
    case theyBlockedMe     // Author blocked the user
    case mutual           // Both users blocked each other
    case listBased        // Blocked via moderation list
    case unknown          // Unknown blocking relationship
}
