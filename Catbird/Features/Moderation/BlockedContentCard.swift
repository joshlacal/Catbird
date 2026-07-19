import SwiftUI
import Petrel
import NukeUI
import OSLog

/// Unified tombstone for blocked content. Calm, informational, direction-aware.
/// Neutral styling only — red is reserved for the destructive confirm button.
struct BlockedContentCard: View {
  enum Variant { case thread, feed, embedCompact, anchor }

  let relationship: BlockRelationship
  let authorDid: String
  /// URI of the blocked post, when the surface has one (nil for profile use).
  let postUri: ATProtocolURI?
  let variant: Variant
  @Binding var path: NavigationPath

  @Environment(AppState.self) private var appState

  @State private var profile: AppBskyActorDefs.ProfileViewDetailed?
  @State private var hydrationSettled = false
  @State private var revealedPost: AppBskyFeedDefs.PostView?
  @State private var isRevealing = false
  @State private var revealFailed = false
  @State private var isConfirmingUnblock = false
  @State private var unblockAffectedConvoCount = 0
  @State private var isUnblocking = false
  @State private var unblockSucceeded = false
  @State private var showIdentifier = false

  private let logger = Logger(subsystem: "blue.catbird", category: "BlockedContentCard")

  var body: some View {
    Group {
      if let revealedPost {
        revealedView(revealedPost)
      } else if variant == .embedCompact {
        compactBody
      } else {
        cardBody
      }
    }
    .task(id: authorDid) {
      profile = await appState.blockedAuthorHydrator?.profile(for: authorDid)
      hydrationSettled = true
    }
    .alert("Unblock", isPresented: $isConfirmingUnblock) {
      Button("Cancel", role: .cancel) {}
      Button("Unblock", role: .destructive) { performUnblock() }
    } message: {
      Text(BlockConfirmation.unblockMessage(handle: profile?.handle.description ?? "this account"))
    }
  }

  // MARK: Compact (quote embeds) — no avatar, no buttons, no navigation

  private var compactBody: some View {
    HStack(spacing: 6) {
      Image(systemName: "hand.raised")
        .foregroundStyle(.secondary)
      Text(compactText)
        .appFont(AppTextRole.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(Color.systemGroupedBackground)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .contentShape(Rectangle())
    .onTapGesture {
      // Only a your-block quote promises a loadable thread (anchor card + reveal live there).
      if relationship.canReveal, relationship.direction == .youBlocked, let postUri {
        path.append(NavigationDestination.post(postUri))
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(compactText)
    .accessibilityHint(
      relationship.direction == .youBlocked && postUri != nil
        ? "Opens the blocked post's thread" : ""
    )
  }

  private var compactText: String {
    if let handle = profile?.handle.description {
      return "\(relationship.statusText) — @\(handle)"
    }
    return relationship.statusText
  }

  // MARK: Full card (thread / feed / anchor)

  private var cardBody: some View {
    VStack(alignment: .leading, spacing: 10) {
      identityRow
      Text(relationship.statusText)
        .appFont(variant == .anchor ? AppTextRole.headline : AppTextRole.subheadline)
        .foregroundStyle(.primary)
      if relationship.direction == .blockedYou || relationship.direction == .mutual {
        Text("Their posts aren't available.")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }
      if variant == .anchor {
        Text("The original post is unavailable, but replies are shown to preserve the conversation.")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }
      if revealFailed {
        Text("This post isn't available.")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }
      actionRow
    }
    .padding(variant == .anchor ? 16 : 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.systemGroupedBackground)
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  private var identityRow: some View {
    HStack(spacing: 8) {
      avatarView
      VStack(alignment: .leading, spacing: 1) {
        if let profile {
          if let displayName = profile.displayName, !displayName.isEmpty {
            Text(displayName)
              .appFont(AppTextRole.subheadline)
              .fontWeight(.medium)
              .lineLimit(1)
          }
          Text("@\(profile.handle.description)")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else if hydrationSettled {
          Text("Blocked account")
            .appFont(AppTextRole.subheadline)
            .fontWeight(.medium)
          Button {
            showIdentifier.toggle()
          } label: {
            Text(showIdentifier ? "Identifier: \(authorDid)" : "Show identifier")
              .appFont(AppTextRole.caption)
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        } else {
          // Stable loading skeleton — generic row, not "redacted".
          Text("Blocked account")
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      // Navigation only when the block is yours; blocked-you identity is informational.
      guard relationship.direction == .youBlocked else { return }
      path.append(NavigationDestination.profile(authorDid))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityIdentityLabel)
    .accessibilityHint(relationship.direction == .youBlocked ? "Opens profile" : "")
  }

  private var accessibilityIdentityLabel: String {
    if let profile {
      let name = profile.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? ""
      return "\(name) @\(profile.handle.description). \(relationship.statusText)"
    }
    return "Blocked account. \(relationship.statusText)"
  }

  private var avatarView: some View {
    Group {
      if let avatarURL = profile?.finalAvatarURL() {
        LazyImage(request: ImageLoadingManager.imageRequest(
          for: avatarURL, targetSize: CGSize(width: 28, height: 28)
        )) { state in
          if let image = state.image {
            image.resizable().aspectRatio(contentMode: .fill)
          } else {
            avatarPlaceholder
          }
        }
        .pipeline(ImageLoadingManager.shared.pipeline)
      } else {
        avatarPlaceholder
      }
    }
    .frame(width: 28, height: 28)
    .clipShape(Circle())
    .accessibilityHidden(true)
  }

  private var avatarPlaceholder: some View {
    Image(systemName: "person.crop.circle.fill")
      .resizable()
      .foregroundStyle(.secondary)
  }

  private var actionRow: some View {
    HStack(spacing: 12) {
      if unblockSucceeded, relationship.canReveal, postUri != nil {
        Button("Load post") { revealPost() }
          .appFont(AppTextRole.callout)
          .disabled(isRevealing)
      } else if relationship.canUnblockDirectly {
        Button {
          prepareUnblock()
        } label: {
          Text("Unblock").appFont(AppTextRole.callout).fontWeight(.medium)
        }
        .disabled(isUnblocking)
        .accessibilityHint("Removes your block on this account. Shows a confirmation first.")
      }
      if let listRef = relationship.listRef {
        Button {
          path.append(NavigationDestination.list(listRef.uri))
        } label: {
          Text("View list").appFont(AppTextRole.callout)
        }
        .accessibilityHint("Opens the list this block comes from")
      }
      Spacer(minLength: 0)
      if relationship.canReveal, postUri != nil, !unblockSucceeded {
        Menu {
          Button("View this post") { revealPost() }
        } label: {
          Image(systemName: "ellipsis.circle")
            .foregroundStyle(.secondary)
            .accessibilityLabel("More options")
        }
        .disabled(isRevealing)
      }
      if isRevealing || isUnblocking { ProgressView().scaleEffect(0.8) }
    }
  }

  // MARK: Revealed state — temporary, in-memory, no engagement actions

  @ViewBuilder
  private func revealedView(_ post: AppBskyFeedDefs.PostView) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(unblockSucceeded ? "" : "Shown once — the account stays blocked")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if !unblockSucceeded {
          Button("Hide again") { revealedPost = nil }
            .appFont(AppTextRole.caption)
            .accessibilityHint("Returns to the blocked-post placeholder")
        }
      }
      PostView(
        post: post,
        grandparentAuthor: nil,
        isParentPost: false,
        isSelectable: false,
        path: $path,
        appState: appState
      )
      .allowsHitTesting(unblockSucceeded)  // no engagement while temporarily revealed
    }
  }

  // MARK: Actions

  private func prepareUnblock() {
    Task {
      if let coord = appState.mlsBlockCoordinator {
        unblockAffectedConvoCount = await coord.affectedConversations(for: authorDid).count
      }
      isConfirmingUnblock = true
    }
  }

  private func performUnblock() {
    isUnblocking = true
    Task {
      defer { isUnblocking = false }
      do {
        // Tombstone stays until the mutation succeeds — no optimistic reveal.
        try await appState.unblock(did: authorDid)
        unblockSucceeded = true
      } catch {
        logger.error("unblock failed: \(error.localizedDescription)")
      }
    }
  }

  private func revealPost() {
    guard let postUri, !isRevealing, let client = appState.atProtoClient else { return }
    isRevealing = true
    revealFailed = false
    Task {
      defer { isRevealing = false }
      do {
        let (_, output) = try await client.app.bsky.feed.getPosts(
          input: AppBskyFeedGetPosts.Parameters(uris: [postUri])
        )
        if let post = output?.posts.first {
          revealedPost = post
        } else {
          revealFailed = true
        }
      } catch {
        logger.error("reveal fetch failed: \(error.localizedDescription)")
        revealFailed = true
      }
    }
  }
}

// MARK: - Preview Stubs

private enum BlockedContentCardPreviewStubs {
  static let authorDid = "did:plc:stubblockedauthor"

  static let postUri: ATProtocolURI = try! ATProtocolURI(
    uriString: "at://did:plc:stubblockedauthor/app.bsky.feed.post/3preview1"
  )

  private static let directBlockUri: ATProtocolURI = try! ATProtocolURI(
    uriString: "at://did:plc:me/app.bsky.graph.block/3previewblock"
  )

  private static let listRef = BlockRelationship.ListRef(
    uri: try! ATProtocolURI(uriString: "at://did:plc:me/app.bsky.graph.list/3previewlist"),
    name: "Preview Blocklist",
    listblockRecordUri: try! ATProtocolURI(uriString: "at://did:plc:me/app.bsky.graph.listblock/3previewlb")
  )

  /// Direct block, viewer → other account.
  static let youBlocked = BlockRelationship(blocking: directBlockUri, blockedBy: false, blockingByList: nil)
  /// Other account blocked the viewer.
  static let blockedYou = BlockRelationship(blocking: nil, blockedBy: true, blockingByList: nil)
  /// Both directions active.
  static let mutual = BlockRelationship(blocking: directBlockUri, blockedBy: true, blockingByList: nil)
  /// Viewer's block comes from a list, not a direct record.
  static let listSourced = BlockRelationship(blocking: nil, blockedBy: nil, blockingByList: listRef)
}

private struct BlockedContentCardVariantPreview: View {
  let variant: BlockedContentCard.Variant
  @State private var path = NavigationPath()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        labeledCard("You blocked them", BlockedContentCardPreviewStubs.youBlocked)
        labeledCard("They blocked you", BlockedContentCardPreviewStubs.blockedYou)
        labeledCard("Mutual block", BlockedContentCardPreviewStubs.mutual)
        labeledCard("Blocked via list", BlockedContentCardPreviewStubs.listSourced)
      }
      .padding()
    }
  }

  @ViewBuilder
  private func labeledCard(_ label: String, _ relationship: BlockRelationship) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.tertiary)
      BlockedContentCard(
        relationship: relationship,
        authorDid: BlockedContentCardPreviewStubs.authorDid,
        postUri: BlockedContentCardPreviewStubs.postUri,
        variant: variant,
        path: $path
      )
    }
  }
}

#Preview("Thread variant") {
  BlockedContentCardVariantPreview(variant: .thread)
    .previewWithAuthenticatedState()
}

#Preview("Feed variant") {
  BlockedContentCardVariantPreview(variant: .feed)
    .previewWithAuthenticatedState()
}

#Preview("Embed compact variant") {
  BlockedContentCardVariantPreview(variant: .embedCompact)
    .previewWithAuthenticatedState()
}

#Preview("Anchor variant") {
  BlockedContentCardVariantPreview(variant: .anchor)
    .previewWithAuthenticatedState()
}
