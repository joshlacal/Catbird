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
  import OSLog

  /// Custom UIActivity for sharing posts to chat
  class ShareToChatActivity: UIActivity {

    private let post: AppBskyFeedDefs.PostView
    private let appState: AppState

    init(post: AppBskyFeedDefs.PostView, appState: AppState) {
      self.post = post
      self.appState = appState
      super.init()
    }

    override var activityType: UIActivity.ActivityType? {
      return UIActivity.ActivityType("blue.catbird.share-to-chat")
    }

    override var activityTitle: String? {
      return "Share to Chat"
    }

    override var activityImage: UIImage? {
      return UIImage(systemName: "bubble.left.and.bubble.right")
    }

    override class var activityCategory: UIActivity.Category {
      return .action
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
      return appState.isAuthenticated
    }

    override func prepare(withActivityItems activityItems: [Any]) {
      // Find the ShareablePost item
      for item in activityItems {
        if let shareablePost = item as? ShareablePost {
          // Store for later use
          break
        }
      }
    }

    override func perform() {
      activityDidFinish(true)
    }

    override var activityViewController: UIViewController? {
      let chatSelectionView = ModernChatSelectionView(post: post, appState: appState) {
        [weak self] in
        self?.activityDidFinish(true)
      }
      .applyAppStateEnvironment(appState)

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

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController)
      -> Any
    {
      let username = post.author.handle
      let recordKey = post.uri.recordKey ?? ""
      return URL(string: "https://bsky.app/profile/\(username)/post/\(recordKey)") ?? ""
    }

    func activityViewController(
      _ activityViewController: UIActivityViewController,
      itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
      if activityType?.rawValue == "blue.catbird.share-to-chat" {
        return post
      }

      let username = post.author.handle
      let recordKey = post.uri.recordKey ?? ""
      return URL(string: "https://bsky.app/profile/\(username)/post/\(recordKey)")
    }
  }

  // MARK: - Modern iOS 18 Chat Selection View

  @available(iOS 18.0, *)
  struct ModernChatSelectionView: View {
    let post: AppBskyFeedDefs.PostView
    let appState: AppState
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var isSearching = false
    @State private var searchResults: [AppBskyActorDefs.ProfileViewBasic] = []
    @State private var keyboardHeight: CGFloat = 0
    @State private var isCreatingConversation = false
    @Environment(\.colorScheme) private var colorScheme

    private let logger = Logger(subsystem: "blue.catbird", category: "ShareToChat")

    var body: some View {
      NavigationStack {
        ZStack {
          // Background
          Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme)
            .ignoresSafeArea()

          VStack(spacing: 0) {
            // Modern search bar
            searchBar
              .padding(.horizontal)
              .padding(.top, 8)

            // Recipients list
            recipientsList
          }
        }
        .navigationTitle("Share to Chat")
        #if os(iOS)
          .toolbarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark") {
              onDismiss()
            }
            .disabled(isCreatingConversation)
          }
        }
        .animation(.smooth(duration: 0.2), value: searchText)
        .overlay {
          if isCreatingConversation {
            ZStack {
              Color.black.opacity(0.2).ignoresSafeArea()
              ProgressView("Starting chat…")
                .padding(20)
                .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
          }
        }
      }
      .onChange(of: searchText) { _, newValue in
        performSearch(newValue)
      }
      .onDisappear {
        // Covers dismissal paths that bypass the (disabled-during-creation) Cancel
        // button, e.g. swiping the UIKit-presented sheet away by its grabber: the
        // in-flight shareToNewConversation completion's `guard isCreatingConversation`
        // then fails and skips the stale navigation.
        isCreatingConversation = false
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
              searchResults = []
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
          if !searchText.isEmpty && !searchResults.isEmpty {
            ForEach(searchResults, id: \.did) { profile in
              ModernRecipientRow(
                title: profile.displayName ?? profile.handle.description,
                subtitle: "@\(profile.handle)",
                avatarURL: profile.avatar?.uriString(),
                isSelected: false,
                showDivider: profile.did != searchResults.last?.did
              ) {
                shareToNewConversation(with: profile)
              }
            }
          }

          // Existing conversations
          if searchText.isEmpty || (!searchText.isEmpty && !filteredConversations.isEmpty) {
            if !searchText.isEmpty && !searchResults.isEmpty {
              sectionHeader("Conversations")
            }

            ForEach(filteredConversations) { conversation in
              conversationRow(conversation)
            }
          }

          // Empty state
          if filteredConversations.isEmpty && searchResults.isEmpty {
            emptyState
          }
        }
        .animation(.default, value: searchResults)
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

    private var emptyState: some View {
      ContentUnavailableView {
        Label("No Results", systemImage: "magnifyingglass")
      } description: {
        Text(
          searchText.isEmpty
            ? "Start typing to search for people" : "No matches found for '\(searchText)'")
      }
      .padding(.vertical, 60)
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
      appState.chatManager.acceptedConversations.filter {
        $0.matchesShareSearch(searchText, currentUserDID: appState.userDID)
      }
    }

    private var recentConversations: [ChatBskyConvoDefs.ConvoView] {
      Array(appState.chatManager.acceptedConversations.prefix(8))
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

    private func shareToConversation(_ conversation: ChatBskyConvoDefs.ConvoView) {
      appState.navigationManager.pendingChatShare = PendingChatShare(
        convoId: conversation.id,
        postRef: ComAtprotoRepoStrongRef(uri: post.uri, cid: post.cid),
        previewEmbed: PendingChatShare.makePreviewEmbed(from: post)
      )
      onDismiss()
      appState.navigationManager.navigate(to: .conversation(conversation.id), in: 4)
      appState.navigationManager.tabSelection?(4)
    }

    private func shareToNewConversation(with profile: AppBskyActorDefs.ProfileViewBasic) {
      guard !isCreatingConversation else { return }
      isCreatingConversation = true
      Task {
        let convoId = await appState.chatManager.startConversationWith(
          userDID: profile.did.didString())
        await MainActor.run {
          // Cancel is disabled while isCreatingConversation is true, but guard anyway:
          // if the sheet was dismissed some other way and this got reset, a stale
          // completion here must not force navigation into a conversation.
          guard isCreatingConversation else { return }
          isCreatingConversation = false
          guard let convoId else {
            logger.error("Share-to-chat: failed to start conversation")
            return
          }
          appState.navigationManager.pendingChatShare = PendingChatShare(
            convoId: convoId,
            postRef: ComAtprotoRepoStrongRef(uri: post.uri, cid: post.cid),
            previewEmbed: PendingChatShare.makePreviewEmbed(from: post)
          )
          onDismiss()
          appState.navigationManager.navigate(to: .conversation(convoId), in: 4)
          appState.navigationManager.tabSelection?(4)
        }
      }
    }

    private func performSearch(_ query: String) {
      guard !query.isEmpty, query.count >= 2 else {
        searchResults = []
        return
      }

      guard let client = appState.atProtoClient else { return }

      Task {
        isSearching = true

        do {
          let params = AppBskyActorSearchActorsTypeahead.Parameters(
            q: query.trimmingCharacters(in: .whitespacesAndNewlines), limit: 10)
          let (responseCode, response) = try await client.app.bsky.actor.searchActorsTypeahead(input: params)

          await MainActor.run {
            isSearching = false

            guard responseCode >= 200 && responseCode < 300,
              let results = response?.actors
            else {
              return
            }

            // Filter out users that already have conversations
            let existingDids = Set(
              appState.chatManager.acceptedConversations.flatMap { conv in
                conv.members.map { $0.did.didString() }
              })

            searchResults = results.filter { profile in
              !existingDids.contains(profile.did.didString())
            }
          }
        } catch {
          await MainActor.run {
            isSearching = false
            logger.error("Search error: \(error.localizedDescription)")
          }
        }
      }
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
