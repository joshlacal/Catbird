import NukeUI
import Petrel
import SwiftUI

/// The thread's anchor post, with its full date, stats and large actions.
///
/// The post is about 3 KB inline, and Debug builds reserve a stack slot for
/// every view temporary a body builds. So the view keeps the post in an
/// `EquatableBox` and renders each section (header, text, embed, stats and
/// actions) in a small child view that holds the box rather than the post.
struct ThreadViewMainPostView: View, Equatable {
  static func == (lhs: ThreadViewMainPostView, rhs: ThreadViewMainPostView) -> Bool {
    lhs.post.value.uri == rhs.post.value.uri && lhs.post.value.indexedAt == rhs.post.value.indexedAt && lhs.viewModel.isBookmarked == rhs.viewModel.isBookmarked && lhs.opThreadPostIndex == rhs.opThreadPostIndex && lhs.opThreadPostCount == rhs.opThreadPostCount
  }

  let post: EquatableBox<AppBskyFeedDefs.PostView>
  let showLine: Bool
  let appState: AppState
  let visibilityContext: PostVisibilityContext
  @Binding var path: NavigationPath
  let opThreadPostIndex: Int?
  let opThreadPostCount: Int?
  @State private var viewModel: PostViewModel
  @State private var contextMenuViewModel: PostContextMenuViewModel
  @State private var currentUserDid: String?
  @State private var prompts = ThreadMainPostPrompts()
  // Using multiples of 3 for spacing
  fileprivate static let baseUnit: CGFloat = 3
  fileprivate static let avatarSize: CGFloat = 48
  fileprivate static let avatarContainerWidth: CGFloat = 54

  fileprivate static let dateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    // Weekday, date and time in the user's locale, honoring their 12/24-hour preference
    formatter.setLocalizedDateFormatFromTemplate("EEEEMMMdyyyyjmm")
    return formatter
  }()

  init(
    post: AppBskyFeedDefs.PostView,
    showLine: Bool,
    path: Binding<NavigationPath>,
    appState: AppState,
    visibilityContext: PostVisibilityContext = .public,
    opThreadPostIndex: Int? = nil,
    opThreadPostCount: Int? = nil
  ) {
    self.init(
      post: EquatableBox(post),
      showLine: showLine,
      path: path,
      appState: appState,
      visibilityContext: visibilityContext,
      opThreadPostIndex: opThreadPostIndex,
      opThreadPostCount: opThreadPostCount
    )
  }

  /// Takes a post that is already boxed, so a caller holding the box never
  /// copies the post back out.
  init(
    post: EquatableBox<AppBskyFeedDefs.PostView>,
    showLine: Bool,
    path: Binding<NavigationPath>,
    appState: AppState,
    visibilityContext: PostVisibilityContext = .public,
    opThreadPostIndex: Int? = nil,
    opThreadPostCount: Int? = nil
  ) {
    self.post = post
    self.showLine = showLine
    self._path = path
    self.appState = appState
    self.visibilityContext = visibilityContext
    self.opThreadPostIndex = opThreadPostIndex
    self.opThreadPostCount = opThreadPostCount
    _viewModel = State(initialValue: PostViewModel(post: post.value, appState: appState, visibilityContext: visibilityContext))
    let actualRootURI = Self.rootURI(of: post.value)
    _contextMenuViewModel = State(
      initialValue: PostContextMenuViewModel(
        appState: appState,
        post: post.value,
        visibilityContext: visibilityContext,
        rootPostURI: actualRootURI,
        rootAuthorDID: actualRootURI.authority
      )
    )
  }

  /// The thread's root post: the record's reply root, else the post itself.
  private static func rootURI(of post: AppBskyFeedDefs.PostView) -> ATProtocolURI {
    if case let .knownType(record) = post.record,
       let feedPost = record as? AppBskyFeedPost,
       let root = feedPost.reply?.root.uri {
      return root
    }
    return post.uri
  }

  private var labelSubject: PostLabelSubject {
    PostLabelSubject(uri: post.value.uri.uriString(), cid: post.value.cid,
      authorDID: post.value.author.did.didString(), authorHandle: post.value.author.handle.description)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ContentLabelView(labels: post.value.labels, selfLabelValues: selfLabelValues,
        subject: labelSubject)
      moderatedBody
        .environment(\.postLabelSummaryIDs, labelSubject.labelIDs(in: post.value.labels))
    }
  }

  private var moderatedBody: some View {
    ContentLabelManager(labels: post.value.labels, selfLabelValues: selfLabelValues, contentType: "post", selfLabelsAlreadyShown: true) {
      ThreadMainPostLayout(
        post: post,
        appState: appState,
        visibilityContext: visibilityContext,
        path: $path,
        opThreadPostIndex: opThreadPostIndex,
        opThreadPostCount: opThreadPostCount,
        viewModel: viewModel,
        contextMenuViewModel: contextMenuViewModel,
        currentUserDid: currentUserDid,
        prompts: $prompts
      )
      // Present the report form when showingReportView is true
      .sheet(isPresented: $prompts.showingReportView) {
        if let client = appState.atProtoClient {
          let reportingService = ReportingService(client: client)
          let subject = contextMenuViewModel.createReportSubject()
          let description = contextMenuViewModel.getReportDescription()

          ReportFormView(
            reportingService: reportingService,
            subject: subject,
            contentDescription: description
          )
        }
      }
      // Present the add to list sheet when showingAddToListSheet is true
      .sheet(isPresented: $prompts.showingAddToListSheet) {
        AddToListSheet(
          userDID: post.value.author.did.didString(),
          userHandle: post.value.author.handle.description,
          userDisplayName: post.value.author.displayName
        )
      }
      .sheet(isPresented: $prompts.showingInteractionSettings) {
        let actualRootURI = Self.rootURI(of: post.value)
        let isRootAuthor = (actualRootURI.authority ?? post.value.author.did.didString()) == appState.userDID

        PostInteractionSettingsView(
          post: post.value,
          rootPostURI: actualRootURI,
          isRootAuthor: isRootAuthor
        )
      }
      .sheet(isPresented: $prompts.showingLabelsOnPost) {
        if let client = appState.atProtoClient {
          let reportingService = ReportingService(client: client)
          let handle = post.value.author.handle.description
          LabelsOnMeView(
            labels: allPostLabels,
            targetDescription: "Post by @\(handle)",
            viewerDID: appState.userDID,
            reportingService: reportingService
          )
        }
      }
      .alert("Delete Post", isPresented: $prompts.showDeleteConfirmation) {
        Button("Cancel", role: .cancel) { }
        Button("Delete", role: .destructive) {
          Task { await deletePostAndLeaveThread() }
        }
      } message: {
        Text("Are you sure you want to delete this post? This can’t be undone.")
      }
      .alert("Mute User", isPresented: $prompts.showMuteUserConfirmation) {
        Button("Cancel", role: .cancel) { }
        Button("Mute", role: .destructive) {
          Task { await contextMenuViewModel.muteUser() }
        }
      } message: {
        Text("Mute @\(post.value.author.handle)? You won’t see their posts and replies in your feeds.")
      }
      .alert("Mute Thread", isPresented: $prompts.showMuteThreadConfirmation) {
        Button("Cancel", role: .cancel) { }
        Button("Mute", role: .destructive) {
          Task { await contextMenuViewModel.muteThread() }
        }
      } message: {
        Text("Mute this thread? You won’t be notified about new replies.")
      }
      .alert("Block User", isPresented: $prompts.showBlockConfirmation) {
        Button("Cancel", role: .cancel) { }
        Button("Block", role: .destructive) {
          Task { await contextMenuViewModel.blockUser() }
        }
      } message: {
        Text("Block @\(post.value.author.handle)? You won’t see each other’s posts, and they won’t be able to follow you.")
      }
      .task(id: post) {
        await setupContextMenu()
      }
    }
  }

  /// Self-applied labels from the record, for visibility decisions.
  private var selfLabelValues: [String] {
    guard case .knownType(let record) = post.value.record,
          let feedPost = record as? AppBskyFeedPost,
          let postLabels = feedPost.labels else { return [] }
    switch postLabels {
    case .comAtprotoLabelDefsSelfLabels(let selfLabels):
      return selfLabels.values.map { $0.val.lowercased() }
    default:
      return []
    }
  }

  // MARK: - Setup & Helpers

  /// Set up the context menu and its callbacks
  private func setupContextMenu() async {
    guard !Task.isCancelled else { return }
    let currentPost = post.value
    if viewModel.postId != currentPost.uri.uriString() || viewModel.postCid != currentPost.cid {
      viewModel = PostViewModel(post: currentPost, appState: appState, visibilityContext: visibilityContext)
    }
    await viewModel.start(post: currentPost)
    guard !Task.isCancelled else { return }
    // Set up report callback
    contextMenuViewModel.onReportPost = {
      prompts.showingReportView = true
    }

    // Set up add to list callback
    contextMenuViewModel.onAddAuthorToList = {
      prompts.showingAddToListSheet = true
    }

    // Set up bookmark callback
    contextMenuViewModel.onToggleBookmark = {
      Task {
        do {
          try await viewModel.toggleBookmark()
        } catch {
          // Handle bookmark error if needed
        }
      }
    }

    // Fetch current user DID
    currentUserDid = appState.userDID
  }

  /// Deletes the post and, once it's gone, leaves the thread screen so nothing
  /// keeps targeting the deleted post.
  @MainActor
  private func deletePostAndLeaveThread() async {
    await contextMenuViewModel.deletePost(visibilityContext: visibilityContext)
    let isDeleted = await appState.postShadowManager.getShadow(forUri: post.value.uri.uriString())?.isDeleted ?? false
    if isDeleted {
      if !path.isEmpty {
        path.removeLast()
      }
    } else {
      appState.toastManager.show(
        ToastItem(message: "Couldn’t delete post. Try again.", icon: "exclamationmark.triangle")
      )
    }
  }

  private var allPostLabels: [ComAtprotoLabelDefs.Label] {
    var combined: [ComAtprotoLabelDefs.Label] = []
    if let postLabels = post.value.labels {
      combined.append(contentsOf: postLabels)
    }
    if let authorLabels = post.value.author.labels {
      combined.append(contentsOf: authorLabels)
    }
    return combined
  }
}

// MARK: - Presentation State

/// The sheets and confirmations the main post presents, held in one `@State`
/// so the options menu can raise any of them through a single binding.
private struct ThreadMainPostPrompts {
  var showingReportView = false
  var showingAddToListSheet = false
  var showDeleteConfirmation = false
  var showBlockConfirmation = false
  var showMuteUserConfirmation = false
  var showMuteThreadConfirmation = false
  var showingInteractionSettings = false
  var showingLabelsOnPost = false
}

// MARK: - Sections

/// Everything below the content-label gate. Each section is its own small view,
/// so this body only holds boxes, flags and the date text.
private struct ThreadMainPostLayout: View {
  let post: EquatableBox<AppBskyFeedDefs.PostView>
  let appState: AppState
  let visibilityContext: PostVisibilityContext
  @Binding var path: NavigationPath
  let opThreadPostIndex: Int?
  let opThreadPostCount: Int?
  let viewModel: PostViewModel
  let contextMenuViewModel: PostContextMenuViewModel
  let currentUserDid: String?
  @Binding var prompts: ThreadMainPostPrompts

  /// The record fields this layout branches on, or `nil` when the record did
  /// not decode as a post. Read in a plain property so the decoded record
  /// never sits in the body's frame.
  private var recordSummary: (hasText: Bool, createdAt: Date)? {
    guard case let .knownType(postObj) = post.value.record,
          let feedPost = postObj as? AppBskyFeedPost else { return nil }
    return (!feedPost.text.isEmpty, feedPost.createdAt.date)
  }

  private var hasEmbed: Bool {
    post.value.embed != nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        if let summary = recordSummary {
          ThreadMainPostHeader(
            post: post,
            appState: appState,
            visibilityContext: visibilityContext,
            path: $path,
            opThreadPostIndex: opThreadPostIndex,
            opThreadPostCount: opThreadPostCount,
            viewModel: viewModel,
            contextMenuViewModel: contextMenuViewModel,
            currentUserDid: currentUserDid,
            prompts: $prompts
          )

          if summary.hasText {
            ThreadMainPostText(post: post, path: $path)
          }

          //              if feedPost.text != "" {
          //
          //                  TappableTextView(
          //                    attributedString: feedPost.facetsAsAttributedString, textSize: nil, textStyle: .title3
          //                  )
          //                  .lineLimit(nil)
          //                  .fixedSize(horizontal: false, vertical: true)
          //                  .padding(.vertical, 6)
          //                  .padding(.leading, 6)
          //                  .padding(.trailing, 6)
          //              }
          if hasEmbed {
            ThreadMainPostEmbed(post: post, visibilityContext: visibilityContext, path: $path)
          }
          Text(ThreadViewMainPostView.dateTimeFormatter.string(from: summary.createdAt))
            .appSubheadline()
            .textScale(.secondary)
            .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
            .padding(ThreadViewMainPostView.baseUnit * 3)
            .transaction { $0.animation = nil }
            .contentTransition(.identity)
        } else {
          // Record failed typed decoding — show the tombstone
          // instead of silently rendering an empty main post.
          ThreadMainPostNotFound(post: post, path: $path)
        }

        ThreadMainPostStats(post: post, path: $path)

        ThreadMainPostActions(post: post, viewModel: viewModel, path: $path)
      }
    }
  }
}

/// Avatar, name and handle, OP-thread position and the options menu.
private struct ThreadMainPostHeader: View {
  let post: EquatableBox<AppBskyFeedDefs.PostView>
  let appState: AppState
  let visibilityContext: PostVisibilityContext
  @Binding var path: NavigationPath
  let opThreadPostIndex: Int?
  let opThreadPostCount: Int?
  let viewModel: PostViewModel
  let contextMenuViewModel: PostContextMenuViewModel
  let currentUserDid: String?
  @Binding var prompts: ThreadMainPostPrompts

  /// The author's display name, falling back to the handle when it is missing or blank.
  private var authorDisplayName: String {
    let name = post.value.author.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return name.isEmpty ? post.value.author.handle.description : name
  }

  private var isSelfDeclaredAutomated: Bool {
    AutomationBadge.isSelfDeclared(labels: post.value.author.labels, authorDID: post.value.author.did)
  }

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      authorAvatarColumn

      authorNameAndHandle
      Spacer()

      if let opThreadPostIndex, let opThreadPostCount {
        ThreadPostNumberView(index: opThreadPostIndex, count: opThreadPostCount)
          .padding(.trailing, 8)
      }

      ThreadMainPostOptionsMenu(
        post: post,
        appState: appState,
        visibilityContext: visibilityContext,
        viewModel: viewModel,
        contextMenuViewModel: contextMenuViewModel,
        currentUserDid: currentUserDid,
        prompts: $prompts
      )
    }
    .frame(minHeight: 60, alignment: .center)
    .padding(.bottom, 3)
  }

  private var authorAvatarColumn: some View {
    VStack(alignment: .leading, spacing: 0) {
      LazyImage(url: post.value.author.finalAvatarURL()) { state in
        if let image = state.image {
          image
            .resizable()
            .aspectRatio(1, contentMode: .fill)
            .frame(width: ThreadViewMainPostView.avatarSize, height: ThreadViewMainPostView.avatarSize)
            .clipShape(Circle())
            .contentShape(Circle())
          //            .overlay(
          //              Circle()
          //                .inset(by: -1.5)
          //                .stroke(colorScheme == .dark ? Color.black : Color.white, lineWidth: 3)
          //            )
        } else {
          Image(systemName: "person.circle.fill")
            .resizable()
            .scaledToFit()
            .frame(width: ThreadViewMainPostView.avatarSize, height: ThreadViewMainPostView.avatarSize)
            .foregroundColor(.gray)
            .contentShape(Circle())
        }
      }
      .onTapGesture {
        path.append(NavigationDestination.profile(post.value.author.did.didString()))
      }
      // The name and handle beside it already open the profile for VoiceOver
      .accessibilityHidden(true)

    }
    .frame(maxHeight: .infinity, alignment: .top)
    .frame(width: ThreadViewMainPostView.avatarContainerWidth)
    .padding(.horizontal, ThreadViewMainPostView.baseUnit)
    // Keep this subtree free of ProfileEntity context. The enclosing
    // thread post is annotated as PostEntity, and iOS 27 can flatten a
    // nested profile DID into that post annotation during collection.
  }

  private var authorNameAndHandle: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        Text(authorDisplayName)
          .lineLimit(1, reservesSpace: true)
          .truncationMode(.tail)
          .appHeadline()
          .themedText(appState.themeManager, style: .primary, appSettings: appState.appSettings)
          .allowsTightening(true)
          .transaction { $0.animation = nil }
          .contentTransition(.identity)

        if let badgeKind = VerificationBadge.kind(for: post.value.author.verification, did: post.value.author.did) {
          VerificationBadgeView(kind: badgeKind)
            .font(.caption)
        }
        if isSelfDeclaredAutomated {
          AutomationBadgeView()
            .layoutPriority(1)
        }

        if let pronouns = post.value.author.pronouns, !pronouns.isEmpty {
          Text("\(pronouns)")
            .appSubheadline()
            .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
            .lineLimit(1)
            .opacity(0.9)
            .textScale(.secondary)
            .padding(1)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
            .background(
              RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.1))
            )

        }

      }
      .padding(.bottom, 1)

      HStack(spacing: 4) {
        Text(verbatim: "@\(post.value.author.handle)")
          .appSubheadline()
          .themedText(appState.themeManager, style: .secondary, appSettings: appState.appSettings)
          .lineLimit(1)
          .truncationMode(.tail)
          .allowsTightening(true)

      }
      .padding(.bottom, 1)
      .transaction { $0.animation = nil }
      .contentTransition(.identity)
    }
    .padding(.leading, 3)
    .padding(.bottom, 4)
    .contentShape(Rectangle())
    .onTapGesture {

      path.append(NavigationDestination.profile(post.value.author.did.didString()))

    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(authorDisplayName), @\(post.value.author.handle.description)"
      + (isSelfDeclaredAutomated ? ", \(AutomationBadge.accessibilityLabel)" : "")
    )
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Opens profile")
  }
}

/// The post's options menu (three dots).
private struct ThreadMainPostOptionsMenu: View {
  let post: EquatableBox<AppBskyFeedDefs.PostView>
  let appState: AppState
  let visibilityContext: PostVisibilityContext
  let viewModel: PostViewModel
  let contextMenuViewModel: PostContextMenuViewModel
  let currentUserDid: String?
  @Binding var prompts: ThreadMainPostPrompts
  @Environment(\.colorScheme) private var colorScheme

  /// Whether the signed-in account wrote this post; own posts get no mute, block, hide or report actions.
  private var isOwnPost: Bool {
    post.value.author.did.didString() == appState.userDID
  }

  var body: some View {
    Menu {
      // Only show "Add to List" for other users' posts
      if post.value.author.did.didString() != currentUserDid {
        Button(action: {
          contextMenuViewModel.addAuthorToList()
        }) {
          Label("Add Author to List", systemImage: "list.bullet.rectangle")
        }

        Divider()
      }

      // Bookmark button - available for all posts
      Button(action: {
        contextMenuViewModel.toggleBookmark()
      }) {
        Label(
          viewModel.isBookmarked ? "Remove Bookmark" : "Bookmark",
          systemImage: viewModel.isBookmarked ? "bookmark.fill" : "bookmark"
        )
      }

      Divider()

      if !isOwnPost {
        Button(action: {
          if DestructiveActionConfirmation.shouldConfirm(
            isEnabled: appState.appSettings.confirmBeforeActions
          ) {
            prompts.showMuteUserConfirmation = true
          } else {
            Task { await contextMenuViewModel.muteUser() }
          }
        }) {
          Label("Mute User", systemImage: "speaker.slash")
        }

        Button(role: .destructive, action: {
          prompts.showBlockConfirmation = true
        }) {
          Label("Block User", systemImage: "exclamationmark.octagon")
        }
      }

      if case .public = visibilityContext {
        Button(action: {
          if DestructiveActionConfirmation.shouldConfirm(
            isEnabled: appState.appSettings.confirmBeforeActions
          ) {
            prompts.showMuteThreadConfirmation = true
          } else {
            Task { await contextMenuViewModel.muteThread() }
          }
        }) {
          Label("Mute Thread", systemImage: "bubble.left.and.bubble.right.fill")
        }
      }

      if !isOwnPost {
        Button(action: {
          Task {
            if contextMenuViewModel.isPostHidden {
              await contextMenuViewModel.unhidePost()
            } else {
              await contextMenuViewModel.hidePost()
            }
          }
        }) {
          Label(
            contextMenuViewModel.isPostHidden ? "Unhide Post" : "Hide Post",
            systemImage: contextMenuViewModel.isPostHidden ? "eye" : "eye.slash"
          )
        }

        Button(action: {
          prompts.showingReportView = true
        }) {
          Label("Report Post", systemImage: "flag")
        }

        // Threadgate OP Moderation (G13): Root author can hide/show replies for everyone
        if contextMenuViewModel.isRootAuthor {
          Button(action: {
            Task {
              if contextMenuViewModel.isReplyHiddenByThreadgate {
                await contextMenuViewModel.unhideReplyForEveryone()
              } else {
                await contextMenuViewModel.hideReplyForEveryone()
              }
            }
          }) {
            Label(
              contextMenuViewModel.isReplyHiddenByThreadgate ? "Show Reply for Everyone" : "Hide Reply for Everyone",
              systemImage: contextMenuViewModel.isReplyHiddenByThreadgate ? "eye" : "eye.slash"
            )
          }
        }

        // Postgate Quote Detachment (G14): Author of quoted post can detach/re-attach quote
        if contextMenuViewModel.quotedPostURI != nil {
          Button(action: {
            Task {
              if contextMenuViewModel.isQuoteDetached {
                await contextMenuViewModel.reattachQuote()
              } else {
                await contextMenuViewModel.detachQuote()
              }
            }
          }) {
            Label(
              contextMenuViewModel.isQuoteDetached ? "Re-attach Quote" : "Detach Quote",
              systemImage: contextMenuViewModel.isQuoteDetached ? "link" : "arrow.branch"
            )
          }
        }
      }

      if let currentUserDid = currentUserDid,
         post.value.author.did.didString() == currentUserDid {
        Button(action: {
          Task { await contextMenuViewModel.togglePin() }
        }) {
          if contextMenuViewModel.isPinned {
            Label("Unpin from Profile", systemImage: "pin.slash")
          } else {
            Label("Pin to Profile", systemImage: "pin")
          }
        }

        Button(action: {
          prompts.showingInteractionSettings = true
        }) {
          Label("Edit Interaction Settings", systemImage: "slider.horizontal.3")
        }

        Button(action: {
          prompts.showingLabelsOnPost = true
        }) {
          Label("View Labels", systemImage: "tag")
        }
        Button(role: .destructive, action: {
          prompts.showDeleteConfirmation = true
        }) {
          Label("Delete Post", systemImage: "trash")
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))
        .padding(ThreadViewMainPostView.baseUnit * 3)
        .contentShape(Rectangle())
        .accessibilityLabel("Post Options")
        .accessibilityAddTraits(.isButton)

    }
  }
}

/// The post text, large and selectable.
private struct ThreadMainPostText: View {
  let post: EquatableBox<AppBskyFeedDefs.PostView>
  @Binding var path: NavigationPath

  var body: some View {
    if case let .knownType(postObj) = post.value.record,
       let feedPost = postObj as? AppBskyFeedPost {
      // Reuse Post component to unify selectable text + translation
      Post(
        post: feedPost,
        isSelectable: true,
        path: $path,
        textSize: 23,
        textStyle: .title3,
        textDesign: .default,
        textWeight: .regular,
        fontWidth: 100,
        lineSpacing: 1.2,
        letterSpacing: 0.2,
        useUIKitSelectableText: true
      )
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, 6)
      .padding(.leading, 6)
      .padding(.trailing, 6)
      .transaction { txn in txn.animation = nil }
      .contentTransition(.identity)
    }
  }
}

/// The post's embed: images, video, link card or quoted record.
private struct ThreadMainPostEmbed: View {
  let post: EquatableBox<AppBskyFeedDefs.PostView>
  let visibilityContext: PostVisibilityContext
  @Binding var path: NavigationPath

  var body: some View {
    if let embed = post.value.embed {
      PostEmbed(
        embed: embed,
        labels: post.value.labels,
        path: $path,
        visibilityContext: visibilityContext,
        authorDID: post.value.author.did
      )
      .padding(.vertical, 6)
      .padding(.leading, 6)
      .padding(.trailing, 6)
    }
  }
}

/// The tombstone shown when the record failed typed decoding.
private struct ThreadMainPostNotFound: View {
  let post: EquatableBox<AppBskyFeedDefs.PostView>
  @Binding var path: NavigationPath

  var body: some View {
    PostNotFoundView(uri: post.value.uri, reason: .parseError, path: $path)
  }
}

/// Reply, repost, like and quote counts and known likers.
private struct ThreadMainPostStats: View {
  let post: EquatableBox<AppBskyFeedDefs.PostView>
  @Binding var path: NavigationPath

  var body: some View {
    PostStatsView(post: post.value, path: $path)
      .padding(.top, ThreadViewMainPostView.baseUnit * 3)
      .padding(.horizontal, 3)
  }
}

/// The large reply, repost, like and share buttons.
private struct ThreadMainPostActions: View {
  let post: EquatableBox<AppBskyFeedDefs.PostView>
  let viewModel: PostViewModel
  @Binding var path: NavigationPath

  var body: some View {
    ActionButtonsView(
      post: post,
      postViewModel: viewModel,
      path: $path,
      isBig: true
    )
    .padding(.leading, 15)
    .padding(.trailing, 9)
  }
}

/// Truncates the string to a specified maximum length, appending a trailing indicator if needed.
extension String {
  func truncated(to length: Int, trailing: String = "...") -> String {
    // If the string exceeds the max length, return a substring with trailing text
    if self.count > length {
      return self.prefix(length) + trailing
    } else {
      return self
    }
  }
}

#Preview("ThreadViewMainPostView") {
  AsyncPreviewDataContent { appState in
    await PreviewData.firstPostView(from: appState)
  } content: { appState, postView in
    ScrollView {
      ThreadViewMainPostView(
        post: postView,
        showLine: false,
        path: .constant(NavigationPath()),
        appState: appState
      )
    }
  }
}
