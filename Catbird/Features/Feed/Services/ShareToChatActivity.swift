//
//  ShareToChatActivity.swift
//  Catbird
//
//  Created for sharing posts to Bluesky chat conversations
//

#if os(iOS)
  import UIKit
  import SwiftUI
  import Petrel
  import Observation

  /// Custom UIActivity for sharing posts to chat
  class ShareToChatActivity: UIActivity {

    private let post: AppBskyFeedDefs.PostView
    private let appState: AppState
    private let sceneContext: SceneNavigationContext

    init(post: AppBskyFeedDefs.PostView, appState: AppState, sceneContext: SceneNavigationContext) {
      self.post = post
      self.appState = appState
      self.sceneContext = sceneContext
      super.init()
    }

    override var activityType: UIActivity.ActivityType? {
      return UIActivity.ActivityType("blue.catbird.share-to-chat")
    }

    override var activityTitle: String? {
      return "Send to Bluesky chat"
    }

    override var activityImage: UIImage? {
      return UIImage(systemName: "bubble.left.and.bubble.right")
    }

    override class var activityCategory: UIActivity.Category {
      return .action
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
      // UIActivity's synchronous availability callback is not actor-isolated.
      // Reject unexpected background queries before reading live scene state.
      guard Thread.isMainThread else { return false }
      return MainActor.assumeIsolated {
        self.appState.isAuthenticated
          && !self.sceneContext.isInvalidated
          && self.sceneContext.accountDID == self.appState.userDID
      }
    }

    override func perform() {
      activityDidFinish(true)
    }

    override var activityViewController: UIViewController? {
      let chatSelectionView = ModernChatSelectionView(post: post, appState: appState, sceneContext: sceneContext) {
        [weak self] in
        self?.activityDidFinish(true)
      }
      .applyAppStateEnvironment(appState)
      .environment(sceneContext)

      let hostingController = UIHostingController(rootView: chatSelectionView)
      hostingController.modalPresentationStyle = .pageSheet

      if let sheet = hostingController.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
        sheet.preferredCornerRadius = 20
      }

      return hostingController
    }
  }

  /// Wrapper for sharing post data
  class ShareablePost: NSObject, UIActivityItemSource {
    let post: AppBskyFeedDefs.PostView

    init(post: AppBskyFeedDefs.PostView) {
      self.post = post
      super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
      ActionButtonViewModel.shareURL(for: post) ?? URL(string: "https://bsky.app")!
    }

    func activityViewController(
      _ activityViewController: UIActivityViewController,
      itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
      if activityType?.rawValue == "blue.catbird.share-to-chat" { return post }
      return ActionButtonViewModel.shareURL(for: post)
    }
  }

  struct NativePostShareSheet: UIViewControllerRepresentable {
    let post: AppBskyFeedDefs.PostView
    let appState: AppState
    let sceneContext: SceneNavigationContext

    func makeUIViewController(context: Context) -> UIActivityViewController {
      UIActivityViewController(
        activityItems: [ShareablePost(post: post)],
        applicationActivities: [ShareToChatActivity(post: post, appState: appState, sceneContext: sceneContext)]
      )
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
  }

  enum ShareRecipientError: LocalizedError {
    case unavailable, lookupFailed, accountChanged

    var errorDescription: String? {
      switch self {
      case .unavailable: "This person can’t receive a Bluesky message from this account."
      case .lookupFailed: "Couldn’t load this chat. Please try again."
      case .accountChanged: "Your account changed. Open sharing again from the account you want to use."
      }
    }

    static func message(for error: Error) -> String {
      if let error = error as? ATProtoError<ChatBskyConvoGetConvoForMembers.Error> {
        switch error.error {
        case .accountSuspended, .blockedActor, .blockedSubject, .messagesDisabled, .notFollowedBySender:
          return ShareRecipientError.unavailable.localizedDescription
        case .recipientNotFound:
          return "This account could not be found. Try another recipient."
        }
      }
      if let error = error as? ShareRecipientError { return error.localizedDescription }
      return ShareRecipientError.lookupFailed.localizedDescription
    }
  }

  /// Owns request identity separately from SwiftUI rendering. A cancelled or
  /// replaced request may finish, but it cannot publish recipients or navigate.
  @MainActor
  @Observable
  final class ShareRecipientSelectionModel {
    let accountDID: String
    let originSceneID: UUID
    private let isOriginValid: () -> Bool
    private let search: (String) async throws -> [AppBskyActorDefs.ProfileViewBasic]
    private let resolve: (String) async throws -> String
    private var searchGeneration = 0
    private var selectionGeneration = 0
    private var cancelled = false

    private(set) var searchResults: [AppBskyActorDefs.ProfileViewBasic] = []
    private(set) var isSearching = false
    private(set) var isSelecting = false
    private(set) var errorMessage: String?

    init(
      accountDID: String,
      originSceneID: UUID,
      isOriginValid: @escaping () -> Bool,
      search: @escaping (String) async throws -> [AppBskyActorDefs.ProfileViewBasic],
      resolve: @escaping (String) async throws -> String
    ) {
      self.accountDID = accountDID
      self.originSceneID = originSceneID
      self.isOriginValid = isOriginValid
      self.search = search
      self.resolve = resolve
    }

    var isCurrent: Bool { !cancelled && isOriginValid() }

    func cancel() {
      cancelled = true
      searchGeneration += 1
      selectionGeneration += 1
      searchResults = []
      isSearching = false
      isSelecting = false
    }

    func searchRecipients(_ text: String, debounce: Duration = .milliseconds(250)) async {
      searchGeneration += 1
      let generation = searchGeneration
      let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
      searchResults = []
      errorMessage = nil
      isSearching = false
      guard isCurrent, query.count >= 2 else { return }
      isSearching = true
      defer { if generation == searchGeneration { isSearching = false } }
      do {
        try await Task.sleep(for: debounce)
        guard isCurrent, !Task.isCancelled, generation == searchGeneration else { return }
        let results = try await search(query)
        guard isCurrent, !Task.isCancelled, generation == searchGeneration else { return }
        searchResults = results.filter { $0.did.didString() != self.accountDID }
      } catch {
        guard isCurrent, !Task.isCancelled, generation == searchGeneration,
              !(error is CancellationError) else { return }
        errorMessage = "Couldn’t search for people. Please try again."
      }
    }

    func select(recipientDID: String) async -> String? {
      guard isCurrent, !isSelecting, recipientDID != accountDID else { return nil }
      selectionGeneration += 1
      let generation = selectionGeneration
      isSelecting = true
      errorMessage = nil
      defer { if generation == selectionGeneration { isSelecting = false } }
      do {
        let convoId = try await resolve(recipientDID)
        guard isCurrent, !Task.isCancelled, generation == selectionGeneration else { return nil }
        return convoId
      } catch {
        guard isCurrent, !Task.isCancelled, generation == selectionGeneration,
              !(error is CancellationError) else { return nil }
        errorMessage = ShareRecipientError.message(for: error)
        return nil
      }
    }

    static func canMessage(_ profile: AppBskyActorDefs.ProfileViewBasic) -> Bool {
      guard profile.viewer?.blockedBy != true, profile.viewer?.blocking == nil,
            profile.viewer?.blockingByList == nil else { return false }
      switch profile.associated?.chat?.allowIncoming {
      case "all": return true
      case "following", nil: return profile.viewer?.followedBy != nil
      default: return false
      }
    }

    private static func cache(_ conversation: ChatBskyConvoDefs.ConvoView, in appState: AppState) {
      // Called synchronously only after the exact-auth response and active-account
      // guards. Keep recipient metadata ready for the destination's preview.
      let manager = appState.chatManager
      if let index = manager.conversations.firstIndex(where: { $0.id == conversation.id }) {
        manager.conversations[index] = conversation
      } else {
        manager.conversations.insert(conversation, at: 0)
      }
      manager.updateConversationsByStatus()
    }

    static func live(appState: AppState, sceneContext: SceneNavigationContext) -> ShareRecipientSelectionModel {
      let accountDID = appState.userDID
      let client = appState.atProtoClient
      // Capture this context, not a proxy for whichever window becomes active.
      let isOriginValid = {
        !sceneContext.isInvalidated && sceneContext.accountDID == accountDID
      }
      return ShareRecipientSelectionModel(
        accountDID: accountDID,
        originSceneID: sceneContext.sceneID,
        isOriginValid: isOriginValid,
        search: { query in
          guard let client, isOriginValid() else { throw ShareRecipientError.accountChanged }
          let continuity = await client.authContinuitySnapshot()
          guard continuity.did == accountDID else { throw ShareRecipientError.accountChanged }
          let result = try await client.performGeneratedRequestWithExactAuthContinuity(matching: continuity) {
            try await client.app.bsky.actor.searchActorsTypeahead(input: .init(q: query, limit: 10))
          }
          guard case .performed(let response) = result else { throw ShareRecipientError.accountChanged }
          guard (200...299).contains(response.responseCode), let data = response.data else {
            throw ShareRecipientError.lookupFailed
          }
          return data.actors
        },
        resolve: { recipientDID in
          guard let client, isOriginValid() else { throw ShareRecipientError.accountChanged }
          let continuity = await client.authContinuitySnapshot()
          guard continuity.did == accountDID else { throw ShareRecipientError.accountChanged }
          let members = try [DID(didString: accountDID), DID(didString: recipientDID)]
          let availability = try await client.performGeneratedRequestWithExactAuthContinuity(matching: continuity) {
            try await client.chat.bsky.convo.getConvoAvailability(input: .init(members: members))
          }
          try Task.checkCancellation()
          guard isOriginValid(),
                case .performed(let response) = availability else { throw ShareRecipientError.accountChanged }
          guard (200...299).contains(response.responseCode), let data = response.data else {
            throw ShareRecipientError.lookupFailed
          }
          guard data.canChat else { throw ShareRecipientError.unavailable }
          if let convo = data.convo {
            guard !convo.isLockedForSending else { throw ShareRecipientError.unavailable }
            cache(convo, in: appState)
            return convo.id
          }
          let creation = try await client.performGeneratedRequestWithExactAuthContinuity(matching: continuity) {
            try await client.chat.bsky.convo.getConvoForMembers(input: .init(members: members))
          }
          try Task.checkCancellation()
          guard isOriginValid(),
                case .performed(let created) = creation else { throw ShareRecipientError.accountChanged }
          guard (200...299).contains(created.responseCode), let convo = created.data?.convo else {
            throw ShareRecipientError.lookupFailed
          }
          guard !convo.isLockedForSending else { throw ShareRecipientError.unavailable }
          cache(convo, in: appState)
          return convo.id
        }
      )
    }
  }

  // MARK: - Modern iOS 18 Chat Selection View

  @available(iOS 18.0, *)
  struct ModernChatSelectionView: View {
    let post: AppBskyFeedDefs.PostView
    let appState: AppState
    let sceneContext: SceneNavigationContext
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var model: ShareRecipientSelectionModel
    @State private var selectionTask: Task<Void, Never>?
    let onSelectConversation: ((String) -> Void)?
    let conversations: [ChatBskyConvoDefs.ConvoView]?
    @Environment(\.colorScheme) private var colorScheme

    init(
      post: AppBskyFeedDefs.PostView,
      appState: AppState,
      sceneContext: SceneNavigationContext,
      model: ShareRecipientSelectionModel? = nil,
      conversations: [ChatBskyConvoDefs.ConvoView]? = nil,
      onSelectConversation: ((String) -> Void)? = nil,
      onDismiss: @escaping () -> Void
    ) {
      self.post = post
      self.appState = appState
      self.sceneContext = sceneContext
      self.onDismiss = onDismiss
      self.onSelectConversation = onSelectConversation
      self.conversations = conversations
      self._model = State(initialValue: model ?? .live(appState: appState, sceneContext: sceneContext))
    }

    var body: some View {
      NavigationStack {
        ZStack {
          // Background
          Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme)
            .ignoresSafeArea()

          VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
              Text(appState.currentUserProfile.map { "Sharing as @\($0.handle.description)" } ?? "Sharing from your account")
                .font(.subheadline.weight(.semibold))
              Text("Choose a chat, then review the post and press Send.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 8)

            // Modern search bar
            searchBar
              .padding(.horizontal)
              .padding(.top, 8)

            if model.isSearching {
              ProgressView("Searching…").padding()
            }
            if let message = model.errorMessage {
              Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .padding()
                .accessibilityIdentifier("shareRecipientError")
            }

            // Recipients list
            recipientsList
              .disabled(model.isSelecting)
          }
        }
        .navigationTitle("Send to Bluesky chat")
        #if os(iOS)
          .toolbarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark") {
              model.cancel()
              selectionTask?.cancel()
              onDismiss()
            }
          }
        }
        .animation(.smooth(duration: 0.2), value: searchText)
        .overlay {
          if model.isSelecting {
            ZStack {
              Color.black.opacity(0.2).ignoresSafeArea()
              ProgressView("Starting chat…")
                .padding(20)
                .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
          }
        }
      }
      .task(id: searchText) {
        guard isValidOrigin else { return }
        await model.searchRecipients(searchText)
      }
      .onChange(of: sceneContext.isInvalidated) { _, isInvalidated in
        if isInvalidated {
          model.cancel()
          selectionTask?.cancel()
          onDismiss()
        }
      }
      .onDisappear {
        model.cancel()
        selectionTask?.cancel()
      }
    }

    // MARK: - View Components

    private var searchBar: some View {
      HStack(spacing: 12) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .fontWeight(.medium)

        TextField("Search people or conversations", text: $searchText)
          .textFieldStyle(.plain)
          .autocorrectionDisabled(true)

        if !searchText.isEmpty {
          Button {
            withAnimation(.smooth(duration: 0.2)) {
              searchText = ""
            }
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
              .imageScale(.medium)
          }
          .transition(.scale.combined(with: .opacity))
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }

    private var recipientsList: some View {
      ScrollView {
        LazyVStack(spacing: 0) {
          if searchText.isEmpty && !recentConversations.isEmpty {
            sectionHeader("Recent")
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 16) {
                ForEach(recentConversations) { conversation in
                  recentChip(conversation)
                }
              }
              .padding(.horizontal)
              .padding(.bottom, 12)
            }
          }

          // Search results
          if !searchText.isEmpty && !model.searchResults.isEmpty {
            ForEach(model.searchResults, id: \.did) { profile in
              ModernRecipientRow(
                title: profile.displayName ?? profile.handle.description,
                subtitle: ShareRecipientSelectionModel.canMessage(profile)
                  ? "@\(profile.handle)" : "Not available for messages",
                avatarURL: profile.avatar?.uriString(),
                isSelected: false,
                showDivider: profile.did != model.searchResults.last?.did,
                isEnabled: ShareRecipientSelectionModel.canMessage(profile)
              ) {
                shareToNewConversation(with: profile)
              }
            }
          }

          // Existing conversations
          if searchText.isEmpty || (!searchText.isEmpty && !filteredConversations.isEmpty) {
            if !searchText.isEmpty && !model.searchResults.isEmpty {
              sectionHeader("Conversations")
            }

            ForEach(filteredConversations) { conversation in
              conversationRow(conversation)
            }
          }

          // Empty state
          if !model.isSearching && model.errorMessage == nil && filteredConversations.isEmpty && model.searchResults.isEmpty {
            emptyState
          }
        }
        .animation(.default, value: model.searchResults)
        .animation(.default, value: filteredConversations)
      }
      .scrollDismissesKeyboard(.interactively)
    }

    private func sectionHeader(_ title: String) -> some View {
      HStack {
        Text(title)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
        Spacer()
      }
      .padding(.horizontal)
      .padding(.vertical, 12)
      .background(.background)
    }

    @ViewBuilder
    private var emptyState: some View {
      let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      if query.isEmpty {
        ContentUnavailableView {
          Label("Search for People", systemImage: "person.crop.circle.badge.plus")
        } description: {
          Text("Search for someone to send this post to.")
        }
        .padding(.vertical, 60)
      } else if query.count < 2 {
        ContentUnavailableView {
          Label("Search for People", systemImage: "magnifyingglass")
        } description: {
          Text("Keep typing to search.")
        }
        .padding(.vertical, 60)
      } else {
        ContentUnavailableView {
          Label("No Results", systemImage: "magnifyingglass")
        } description: {
          Text("No matches for “\(query)”")
        }
        .padding(.vertical, 60)
      }
    }

    @ViewBuilder
    private func conversationRow(_ conversation: ChatBskyConvoDefs.ConvoView) -> some View {
      let userDID = appState.userDID
      let isLocked = conversation.isLockedForSending
      let participants: [ChatParticipant]? =
        conversation.isGroupConversation
        ? conversation.displayMembersExcludingCurrentUser(currentUserDID: userDID).map { member in
            ChatParticipant(
              id: member.did.didString(),
              handle: member.handle.description,
              displayName: member.displayName,
              avatarURL: member.finalAvatarURL()
            )
          }
        : nil

      ModernRecipientRow(
        title: conversation.displayTitle(currentUserDID: userDID),
        subtitle: isLocked
          ? "Locked"
          : (conversation.displaySubtitle(currentUserDID: userDID) ?? ""),
        avatarURL: conversation.directDisplayMember(currentUserDID: userDID)?
          .avatar?.uriString(),
        isSelected: false,
        showDivider: conversation.id != filteredConversations.last?.id,
        groupParticipants: participants,
        isEnabled: !isLocked
      ) {
        shareToConversation(conversation)
      }
    }

    // MARK: - Helper Methods

    private var filteredConversations: [ChatBskyConvoDefs.ConvoView] {
      (conversations ?? appState.chatManager.acceptedConversations).filter {
        $0.matchesShareSearch(searchText, currentUserDID: appState.userDID)
      }
    }

    private var recentConversations: [ChatBskyConvoDefs.ConvoView] {
      Array((conversations ?? appState.chatManager.acceptedConversations).prefix(8))
    }

    @ViewBuilder
    private func recentChip(_ conversation: ChatBskyConvoDefs.ConvoView) -> some View {
      let userDID = appState.userDID
      Button {
        shareToConversation(conversation)
      } label: {
        VStack(spacing: 6) {
          if conversation.isGroupConversation {
            ChatGroupAvatarView(
              participants: conversation
                .displayMembersExcludingCurrentUser(currentUserDID: userDID)
                .map { member in
                  ChatParticipant(
                    id: member.did.didString(),
                    handle: member.handle.description,
                    displayName: member.displayName,
                    avatarURL: member.finalAvatarURL()
                  )
                },
              size: 56
            )
          } else {
            ChatProfileAvatarView(
              profile: conversation.directDisplayMember(currentUserDID: userDID),
              size: 56
            )
          }
          Text(conversation.displayTitle(currentUserDID: userDID))
            .font(.caption2)
            .lineLimit(1)
            .frame(width: 64)
        }
      }
      .buttonStyle(.plain)
      .disabled(conversation.isLockedForSending)
      .opacity(conversation.isLockedForSending ? 0.5 : 1.0)
    }

    private var isValidOrigin: Bool {
      !sceneContext.isInvalidated
        && sceneContext.accountDID == appState.userDID
        && model.accountDID == sceneContext.accountDID
        && model.originSceneID == sceneContext.sceneID
        && model.isCurrent
    }

    private func shareToConversation(_ conversation: ChatBskyConvoDefs.ConvoView) {
      guard isValidOrigin, !model.isSelecting, !conversation.isLockedForSending,
            conversation.members.contains(where: { $0.did.didString() == model.accountDID }) else { return }
      finishSelection(convoId: conversation.id)
    }

    private func shareToNewConversation(with profile: AppBskyActorDefs.ProfileViewBasic) {
      guard isValidOrigin, !model.isSelecting, ShareRecipientSelectionModel.canMessage(profile) else { return }
      selectionTask?.cancel()
      selectionTask = Task {
        guard let convoId = await model.select(recipientDID: profile.did.didString()) else { return }
        finishSelection(convoId: convoId)
      }
    }

    private func finishSelection(convoId: String) {
      guard isValidOrigin else { return }
      if let onSelectConversation {
        onSelectConversation(convoId)
      } else {
        let navigation = sceneContext.navigationManager
        navigation.updateCurrentTab(AppNavigationManager.chatTabIndex)
        navigation.tabSelection?(AppNavigationManager.chatTabIndex)
        // A tab-selection callback can synchronously invalidate its context.
        guard isValidOrigin else { return }
        PendingChatShareStore.shared.stage(PendingChatShare(
          originSceneID: sceneContext.sceneID,
          accountDID: model.accountDID,
          convoId: convoId,
          postRef: ComAtprotoRepoStrongRef(uri: post.uri, cid: post.cid),
          previewEmbed: PendingChatShare.makePreviewEmbed(from: post)
        ))
        navigation.navigate(to: .conversation(convoId), in: AppNavigationManager.chatTabIndex)
      }
      model.cancel()
      onDismiss()
    }
  }

  // MARK: - Modern Recipient Row

  @available(iOS 18.0, *)
  struct ModernRecipientRow: View {
    let title: String
    let subtitle: String
    let avatarURL: String?
    let isSelected: Bool
    let showDivider: Bool
    var groupParticipants: [ChatParticipant]?
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
      Button(action: action) {
        HStack(spacing: 14) {
          // Avatar
          Group {
            if let groupParticipants, !groupParticipants.isEmpty {
              ChatGroupAvatarView(participants: groupParticipants, size: 48)
            } else if let avatarURL = avatarURL,
              let url = URL(string: avatarURL)
            {
              AsyncImage(url: url) { image in
                image
                  .resizable()
                  .scaledToFill()
              } placeholder: {
                Circle()
                  .fill(.quaternary)
              }
              .frame(width: 48, height: 48)
              .clipShape(Circle())
            } else {
              Circle()
                .fill(.quaternary)
                .overlay {
                  Text(title.prefix(1))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                }
                .frame(width: 48, height: 48)
            }
          }
          .frame(width: 48, height: 48)

          VStack(alignment: .leading, spacing: 4) {
            Text(title)
              .font(.body.weight(.medium))
              .foregroundStyle(.primary)
              .lineLimit(1)

            Text(subtitle)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }

          Spacer()

          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(.accent)
              .imageScale(.large)
              .transition(.scale.combined(with: .opacity))
          }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(isPressed ? Color.secondary.opacity(0.1) : Color.clear)
      }
      .buttonStyle(.plain)
      .disabled(!isEnabled)
      .opacity(isEnabled ? 1.0 : 0.5)
      .scaleEffect(isPressed ? 0.98 : 1.0)
      .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) { pressing in
        withAnimation(.easeInOut(duration: 0.1)) {
          isPressed = pressing
        }
      } perform: {
      }

      if showDivider {
        Divider()
          .padding(.leading, 78)
      }
    }
  }

  // MARK: - Post Preview Sheet

  @available(iOS 18.0, *)
  struct PostPreviewSheet: View {
    let post: AppBskyFeedDefs.PostView
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            // Author info
            HStack(spacing: 12) {
              if let avatarURL = post.author.avatar?.uriString(),
                let url = URL(string: avatarURL)
              {
                AsyncImage(url: url) { image in
                  image
                    .resizable()
                    .scaledToFill()
                } placeholder: {
                  Circle()
                    .fill(.quaternary)
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
              }

              VStack(alignment: .leading, spacing: 2) {
                Text(post.author.displayName ?? post.author.handle.description)
                  .font(.subheadline.weight(.semibold))
                Text("@\(post.author.handle)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              Spacer()
            }

            // Post content
            if case .knownType(let record) = post.record,
              let postRecord = record as? AppBskyFeedPost
            {
              Text(postRecord.text)
                .font(.body)
            }

            // Post stats
            HStack(spacing: 24) {
              Label("\(post.likeCount ?? 0)", systemImage: "heart")
              Label("\(post.repostCount ?? 0)", systemImage: "arrow.2.squarepath")
              Label("\(post.replyCount ?? 0)", systemImage: "bubble.left")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .padding()
          .background(.regularMaterial, in: .rect(cornerRadius: 16))
          .padding()
        }
        .navigationTitle("Post Preview")
        #if os(iOS)
          .toolbarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
              Button {
                  dismiss()
              } label: {
                  Image(systemName: "checkmark")
              }
          }
        }
      }
    }
  }

#else
  import Petrel
  import SwiftUI

  // macOS stubs for sharing functionality
  class ShareToChatActivity {
    init(post: AppBskyFeedDefs.PostView, appState: AppState) {
      // macOS stub - sharing features not available
    }
  }

  class ShareablePost {
    init(post: AppBskyFeedDefs.PostView) {
      // macOS stub
    }
  }

#endif
