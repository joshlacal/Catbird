import SwiftUI
import Petrel
import NukeUI
import OSLog

/// Unified tombstone for blocked content. Calm, informational, direction-aware.
/// Neutral styling only — red is reserved for the destructive confirm button.
///
/// The card owns the state and the actions, and each surface it shows is a
/// small child view. It never holds a hydrated profile or a revealed post
/// inline: this card sits inside feed rows, quote embeds and thread rows, and
/// Debug builds give every `some View` temporary in a body its own stack slot,
/// so kilobyte-sized fields here multiply through every container's frame.
struct BlockedContentCard: View {
  enum Variant { case thread, feed, embedCompact, anchor }

  let relationship: BlockRelationship
  let authorDid: String
  /// URI of the blocked post, when the surface has one (nil for profile use).
  private let postUri: EquatableBox<ATProtocolURI>?
  let variant: Variant
  @Binding var path: NavigationPath

  @Environment(AppState.self) private var appState
  @Environment(\.isReadOnlyPostPreview) private var isReadOnlyPreview

  @State private var cardState = BlockedContentCardState()

  private let logger = Logger(subsystem: "blue.catbird", category: "BlockedContentCard")

  init(
    relationship: BlockRelationship,
    authorDid: String,
    postUri: ATProtocolURI?,
    variant: Variant,
    path: Binding<NavigationPath>
  ) {
    self.relationship = relationship
    self.authorDid = authorDid
    self.postUri = postUri.map { EquatableBox($0) }
    self.variant = variant
    self._path = path
  }

  var body: some View {
    Group {
      if let revealedPost = cardState.revealedPost {
        BlockedContentRevealedPost(
          post: revealedPost,
          unblockSucceeded: cardState.unblockSucceeded,
          revealedPost: $cardState.revealedPost,
          path: $path
        )
      } else if variant == .embedCompact {
        BlockedContentCompactRow(
          text: compactText,
          tapTarget: isCompactTapActionable ? postUri : nil,
          path: $path
        )
      } else {
        BlockedContentFullCard(
          relationship: relationship,
          authorDid: authorDid,
          variant: variant,
          identity: cardState.identity,
          hydrationSettled: cardState.hydrationSettled,
          hasPostUri: postUri != nil,
          revealFailed: cardState.revealFailed,
          isRevealing: cardState.isRevealing,
          isUnblocking: cardState.isUnblocking,
          unblockSucceeded: cardState.unblockSucceeded,
          showIdentifier: $cardState.showIdentifier,
          path: $path,
          onReveal: { revealPost() },
          onUnblock: { prepareUnblock() }
        )
      }
    }
    .task(id: authorDid) {
      let profile = await appState.blockedAuthorHydrator?.profile(for: authorDid)
      cardState.identity = profile.map { BlockedAuthorIdentity(profile: $0) }
      cardState.hydrationSettled = true
    }
    .alert("Unblock", isPresented: $cardState.isConfirmingUnblock) {
      Button("Cancel", role: .cancel) {}
      Button("Unblock", role: .destructive) { performUnblock() }
    } message: {
      Text(BlockConfirmation.unblockMessage(handle: cardState.identity?.handle ?? "this account"))
    }
  }

  // MARK: Compact (quote embeds)

  /// Only a your-block quote promises a loadable thread (anchor card + reveal live there).
  private var isCompactTapActionable: Bool {
    !isReadOnlyPreview && relationship.canReveal && relationship.direction == .youBlocked && postUri != nil
  }

  private var compactText: String {
    if let handle = cardState.identity?.handle {
      return "\(relationship.statusText) — @\(handle)"
    }
    return relationship.statusText
  }

  // MARK: Actions

  private func prepareUnblock() {
    guard !isReadOnlyPreview else { return }
    // Synchronous: no async gap between tap and the alert becoming modal,
    // so there's no window for a second tap to re-fire the mutation. The
    // shared-conversation caveat is static copy in `BlockConfirmation`, not
    // a live count, so no coordinator query is needed here.
    cardState.isConfirmingUnblock = true
  }

  private func performUnblock() {
    guard !isReadOnlyPreview else { return }
    cardState.isUnblocking = true
    Task {
      defer { cardState.isUnblocking = false }
      do {
        // Tombstone stays until the mutation succeeds — no optimistic reveal.
        try await appState.unblock(did: authorDid)
        cardState.unblockSucceeded = true
      } catch {
        logger.error("unblock failed: \(error.localizedDescription)")
        appState.toastManager.show(ToastItem(
          message: "Couldn’t unblock this account. Try again.", icon: "exclamationmark.triangle.fill"))
      }
    }
  }

  private func revealPost() {
    guard let postUri, !cardState.isRevealing, let client = appState.atProtoClient else { return }
    cardState.isRevealing = true
    cardState.revealFailed = false
    Task {
      defer { cardState.isRevealing = false }
      do {
        let (_, output) = try await client.app.bsky.feed.getPosts(
          input: AppBskyFeedGetPosts.Parameters(uris: [postUri.value])
        )
        if let post = output?.posts.first {
          cardState.revealedPost = EquatableBox(post)
        } else {
          cardState.revealFailed = true
        }
      } catch {
        logger.error("reveal fetch failed: \(error.localizedDescription)")
        cardState.revealFailed = true
      }
    }
  }
}

// MARK: - Card State

/// The card's transient state in one `@State`. Each `@State` property with an
/// initial value costs the card 32 bytes or more of inline storage, and the
/// card is stored inline in the body type of every view that shows one.
private struct BlockedContentCardState: Equatable {
  var identity: BlockedAuthorIdentity?
  var hydrationSettled = false
  var revealedPost: EquatableBox<AppBskyFeedDefs.PostView>?
  var isRevealing = false
  var revealFailed = false
  var isConfirmingUnblock = false
  var isUnblocking = false
  var unblockSucceeded = false
  var showIdentifier = false
}

// MARK: - Hydrated Identity

/// The profile fields the card shows. The card keeps these rather than the
/// hydrated `ProfileViewDetailed`, which is about 5 KB stored inline.
private struct BlockedAuthorIdentity: Equatable {
  let handle: String
  let displayName: String?
  let avatarURL: URL?

  init(profile: AppBskyActorDefs.ProfileViewDetailed) {
    handle = profile.handle.description
    displayName = profile.displayName
    avatarURL = profile.finalAvatarURL()
  }
}

// MARK: - Compact Row

/// Quote-embed variant: no avatar, no buttons, no navigation beyond the
/// optional tap into the blocked post's thread.
private struct BlockedContentCompactRow: View {
  let text: String
  /// The post whose thread a tap opens; nil when this direction offers no action.
  let tapTarget: EquatableBox<ATProtocolURI>?
  @Binding var path: NavigationPath

  var body: some View {
    let content = HStack(spacing: 6) {
      Image(systemName: "hand.raised")
        .foregroundStyle(.secondary)
      Text(text)
        .appFont(AppTextRole.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(Color.systemGroupedBackground)
    .clipShape(RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(text)
    .accessibilityHint(tapTarget != nil ? "Opens the blocked post's thread" : "")

    if let tapTarget {
      content
        .contentShape(Rectangle())
        .onTapGesture {
          path.append(NavigationDestination.post(tapTarget.value))
        }
    } else {
      // No action for this direction — let the tap fall through to the
      // enclosing quoted-post cell instead of swallowing it here.
      content
    }
  }
}

// MARK: - Full Card (thread / feed / anchor)

private struct BlockedContentFullCard: View {
  let relationship: BlockRelationship
  let authorDid: String
  let variant: BlockedContentCard.Variant
  let identity: BlockedAuthorIdentity?
  let hydrationSettled: Bool
  let hasPostUri: Bool
  let revealFailed: Bool
  let isRevealing: Bool
  let isUnblocking: Bool
  let unblockSucceeded: Bool
  @Binding var showIdentifier: Bool
  @Binding var path: NavigationPath
  let onReveal: () -> Void
  let onUnblock: () -> Void

  @Environment(\.isReadOnlyPostPreview) private var isReadOnlyPreview

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      BlockedContentIdentityRow(
        relationship: relationship,
        authorDid: authorDid,
        identity: identity,
        hydrationSettled: hydrationSettled,
        showIdentifier: $showIdentifier,
        path: $path
      )
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
      if !isReadOnlyPreview {
        BlockedContentActionRow(
          relationship: relationship,
          hasPostUri: hasPostUri,
          isRevealing: isRevealing,
          isUnblocking: isUnblocking,
          unblockSucceeded: unblockSucceeded,
          path: $path,
          onReveal: onReveal,
          onUnblock: onUnblock
        )
      }
    }
    .padding(variant == .anchor ? 16 : 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.systemGroupedBackground)
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }
}

// MARK: - Identity Row

private struct BlockedContentIdentityRow: View {
  let relationship: BlockRelationship
  let authorDid: String
  let identity: BlockedAuthorIdentity?
  let hydrationSettled: Bool
  @Binding var showIdentifier: Bool
  @Binding var path: NavigationPath

  @Environment(\.isReadOnlyPostPreview) private var isReadOnlyPreview

  var body: some View {
    HStack(spacing: 8) {
      avatarView
      VStack(alignment: .leading, spacing: 1) {
        if let identity {
          if let displayName = identity.displayName, !displayName.isEmpty {
            Text(displayName)
              .appFont(AppTextRole.subheadline)
              .fontWeight(.medium)
              .lineLimit(1)
          }
          Text("@\(identity.handle)")
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
      guard !isReadOnlyPreview, relationship.direction == .youBlocked else { return }
      path.append(NavigationDestination.profile(authorDid))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityIdentityLabel)
    .accessibilityHint(!isReadOnlyPreview && relationship.direction == .youBlocked ? "Opens profile" : "")
    .accessibilityActions {
      // The disclosure button is swallowed by `.combine` above — expose its
      // toggle as a discoverable, actuatable VoiceOver custom action instead.
      if identity == nil, hydrationSettled {
        Button(showIdentifier ? "Hide identifier" : "Show identifier") {
          showIdentifier.toggle()
        }
      }
    }
  }

  private var accessibilityIdentityLabel: String {
    if let identity {
      let name = identity.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? ""
      return "\(name) @\(identity.handle). \(relationship.statusText)"
    }
    if showIdentifier {
      return "Blocked account. Identifier \(authorDid). \(relationship.statusText)"
    }
    return "Blocked account. \(relationship.statusText)"
  }

  private var avatarView: some View {
    Group {
      if let avatarURL = identity?.avatarURL {
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
}

// MARK: - Action Row

private struct BlockedContentActionRow: View {
  let relationship: BlockRelationship
  let hasPostUri: Bool
  let isRevealing: Bool
  let isUnblocking: Bool
  let unblockSucceeded: Bool
  @Binding var path: NavigationPath
  let onReveal: () -> Void
  let onUnblock: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      if unblockSucceeded, relationship.canReveal, hasPostUri {
        Button("Load post") { onReveal() }
          .appFont(AppTextRole.callout)
          .disabled(isRevealing)
      } else if unblockSucceeded {
        // No post to load (profile use, or reveal not applicable) — say so
        // plainly rather than re-showing an "Unblock" action that would refire.
        Text("Unblocked")
          .appFont(AppTextRole.callout)
          .foregroundStyle(.secondary)
      } else if relationship.canUnblockDirectly {
        Button {
          onUnblock()
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
      if relationship.canReveal, hasPostUri, !unblockSucceeded {
        Menu {
          Button("View this post") { onReveal() }
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
}

// MARK: - Revealed Post

/// Temporary, in-memory reveal of the blocked post — no engagement actions
/// until an unblock succeeds.
private struct BlockedContentRevealedPost: View {
  let post: EquatableBox<AppBskyFeedDefs.PostView>
  let unblockSucceeded: Bool
  @Binding var revealedPost: EquatableBox<AppBskyFeedDefs.PostView>?
  @Binding var path: NavigationPath

  @Environment(AppState.self) private var appState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        if !unblockSucceeded {
          Text("Shown once — the account stays blocked")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !unblockSucceeded {
          Button("Hide again") { revealedPost = nil }
            .appFont(AppTextRole.caption)
            .accessibilityHint("Returns to the blocked-post placeholder")
        }
      }
      makePostView()
        .allowsHitTesting(unblockSucceeded)  // no engagement while temporarily revealed
    }
  }

  /// Builds the post view in its own short-lived frame, so the copy of the
  /// boxed post that `PostView.init` takes never gets a slot in `body`'s frame.
  private func makePostView() -> PostView {
    PostView(
      post: post.value,
      grandparentAuthor: nil,
      isParentPost: false,
      isSelectable: false,
      path: $path,
      appState: appState
    )
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
