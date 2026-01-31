import CatbirdMLSService
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
  import CatbirdMLSCore
  import GRDB

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

  /// Custom UIActivity for sharing posts to MLS secure chats
  class ShareToMLSChatActivity: UIActivity {

    private let post: AppBskyFeedDefs.PostView
    private let appState: AppState

    init(post: AppBskyFeedDefs.PostView, appState: AppState) {
      self.post = post
      self.appState = appState
      super.init()
    }

    override var activityType: UIActivity.ActivityType? {
      return UIActivity.ActivityType("blue.catbird.share-to-mls-chat")
    }

    override var activityTitle: String? {
      return "Share to Secure Chat"
    }

    override var activityImage: UIImage? {
      return UIImage(systemName: "lock.shield")
    }

    override class var activityCategory: UIActivity.Category {
      return .action
    }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
      return appState.isAuthenticated
    }

    override func prepare(withActivityItems activityItems: [Any]) {
      // Prepare for sharing
    }

    override func perform() {
      activityDidFinish(true)
    }

    override var activityViewController: UIViewController? {
      let mlsChatSelectionView = MLSChatSelectionView(post: post, appState: appState) {
        [weak self] in
        self?.activityDidFinish(true)
      }
      .applyAppStateEnvironment(appState)

      let hostingController = UIHostingController(rootView: mlsChatSelectionView)
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
    @State private var messageText = ""
    @State private var selectedRecipient: RecipientSelection? = nil
    @State private var isSending = false
    @State private var isSearching = false
    @State private var searchResults: [AppBskyActorDefs.ProfileViewBasic] = []
    @State private var showingPostPreview = false
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var isMessageFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private let logger = Logger(subsystem: "blue.catbird", category: "ShareToChat")

    enum RecipientSelection: Equatable {
      case conversation(ChatBskyConvoDefs.ConvoView)
      case profile(AppBskyActorDefs.ProfileViewBasic)

      var displayName: String {
        switch self {
        case .conversation(let convo):
          if let member = convo.members.first {
            return member.displayName ?? "@\(member.handle)"
          }
          return "Unknown"
        case .profile(let profile):
          return profile.displayName ?? "@\(profile.handle)"
        }
      }

      var handle: String {
        switch self {
        case .conversation(let convo):
          if let member = convo.members.first {
            return "@\(member.handle)"
          }
          return ""
        case .profile(let profile):
          return "@\(profile.handle)"
        }
      }

      var avatarURL: String? {
        switch self {
        case .conversation(let convo):
          return convo.members.first?.avatar?.uriString()
        case .profile(let profile):
          return profile.avatar?.uriString()
        }
      }
    }

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

            // Selected recipient chip
            if let recipient = selectedRecipient {
              selectedRecipientView(recipient)
                .transition(
                  .asymmetric(
                    insertion: .push(from: .bottom).combined(with: .opacity),
                    removal: .push(from: .top).combined(with: .opacity)
                  ))
            }

            // Message composer
            if selectedRecipient != nil {
              messageComposer
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

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
            .disabled(isSending)
          }

          ToolbarItem(placement: .primaryAction) {
            if selectedRecipient != nil {
              sendButton
            }
          }
        }
        .sheet(isPresented: $showingPostPreview) {
          PostPreviewSheet(post: post)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .animation(.smooth(duration: 0.3), value: selectedRecipient)
        .animation(.smooth(duration: 0.2), value: searchText)
      }
      .onChange(of: searchText) { _, newValue in
        performSearch(newValue)
      }
      .onAppear {
        isMessageFieldFocused = false
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

    private func selectedRecipientView(_ recipient: RecipientSelection) -> some View {
      HStack(spacing: 12) {
        // Avatar
        Group {
          if let avatarURL = recipient.avatarURL,
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
          } else {
            Circle()
              .fill(.quaternary)
              .overlay {
                Text(recipient.displayName.prefix(1))
                  .font(.callout.bold())
                  .foregroundStyle(.secondary)
              }
          }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())

        VStack(alignment: .leading, spacing: 2) {
          Text(recipient.displayName)
            .font(.subheadline.weight(.medium))
          Text(recipient.handle)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          withAnimation(.smooth(duration: 0.2)) {
            selectedRecipient = nil
            isMessageFieldFocused = false
          }
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .imageScale(.medium)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
      .padding(.horizontal)
      .padding(.vertical, 8)
    }

    private var messageComposer: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Message")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)

          Spacer()

          // Post preview button
          Button {
            showingPostPreview = true
          } label: {
            Label("Preview", systemImage: "eye")
              .font(.caption.weight(.medium))
              .foregroundStyle(.accent)
          }

          Text("\(messageText.count)/1000")
            .font(.caption2)
            .foregroundStyle(
              messageText.count > 900
                ? .red
                : Color.dynamicTertiaryBackground(appState.themeManager, currentScheme: colorScheme)
            )
            .contentTransition(.numericText())
        }

        TextEditor(text: $messageText)
          .focused($isMessageFieldFocused)
          .scrollContentBackground(.hidden)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.regularMaterial, in: .rect(cornerRadius: 12))
          .frame(minHeight: 80, maxHeight: 120)
          .onChange(of: messageText) { _, newValue in
            if newValue.count > 1000 {
              messageText = String(newValue.prefix(1000))
            }
          }

        Text("The post will be attached automatically")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal)
      .padding(.bottom, 8)
    }

    private var sendButton: some View {
      Button {
        sendMessage()
      } label: {
        if isSending {
          ProgressView()
            .controlSize(.small)
        } else {
          Text("Send")
            .fontWeight(.semibold)
        }
      }
      .disabled(isSending)
    }

    private var recipientsList: some View {
      ScrollView {
        LazyVStack(spacing: 0) {
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
                selectProfile(profile)
              }
            }
          }

          // Existing conversations
          if searchText.isEmpty || (!searchText.isEmpty && !filteredConversations.isEmpty) {
            if !searchText.isEmpty && !searchResults.isEmpty {
              sectionHeader("Conversations")
            }

            ForEach(filteredConversations) { conversation in
              if let otherMember = conversation.members.first(where: {
                $0.did.didString() != appState.userDID
              }) {
                ModernRecipientRow(
                  title: otherMember.displayName ?? otherMember.handle.description,
                  subtitle: "@\(otherMember.handle)",
                  avatarURL: otherMember.avatar?.uriString(),
                  isSelected: false,
                  showDivider: conversation.id != filteredConversations.last?.id
                ) {
                  selectConversation(conversation)
                }
              }
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

    // MARK: - Helper Methods

    private var filteredConversations: [ChatBskyConvoDefs.ConvoView] {
      let conversations = appState.chatManager.acceptedConversations

      if searchText.isEmpty {
        return conversations
      }

      return conversations.filter { conversation in
        guard
          let otherMember = conversation.members.first(where: {
            $0.did.didString() != appState.userDID
          })
        else {
          return false
        }

        let displayName = otherMember.displayName ?? ""
        let handle = otherMember.handle.description

        return displayName.localizedCaseInsensitiveContains(searchText)
          || handle.localizedCaseInsensitiveContains(searchText)
      }
    }

    private func selectProfile(_ profile: AppBskyActorDefs.ProfileViewBasic) {
      withAnimation(.smooth(duration: 0.3)) {
        selectedRecipient = .profile(profile)
        searchText = ""
        searchResults = []
        isMessageFieldFocused = true
      }
    }

    private func selectConversation(_ conversation: ChatBskyConvoDefs.ConvoView) {
      withAnimation(.smooth(duration: 0.3)) {
        selectedRecipient = .conversation(conversation)
        searchText = ""
        isMessageFieldFocused = true
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

    private func sendMessage() {
      guard let recipient = selectedRecipient else { return }

      isSending = true

      switch recipient {
      case .conversation(let conversation):
        sendToConversation(conversation)
      case .profile(let profile):
        sendToNewConversation(with: profile)
      }
    }

    private func sendToConversation(_ conversation: ChatBskyConvoDefs.ConvoView) {
      Task {
        await MainActor.run {
          onDismiss()

          // Navigate to conversation
          appState.navigationManager.navigate(
            to: .conversation(conversation.id),
            in: 4
          )
          appState.navigationManager.tabSelection?(4)
        }

        // Send message in background
        let strongRef = ComAtprotoRepoStrongRef(uri: post.uri, cid: post.cid)
        let recordEmbed = AppBskyEmbedRecord(record: strongRef)
        let embed = ChatBskyConvoDefs.MessageInputEmbedUnion.appBskyEmbedRecord(recordEmbed)

        _ = await appState.chatManager.sendMessage(
          convoId: conversation.id,
          text: messageText,
          embed: embed
        )
      }
    }

    private func sendToNewConversation(with profile: AppBskyActorDefs.ProfileViewBasic) {
      Task {
        if let convoId = await appState.chatManager.startConversationWith(
          userDID: profile.did.didString())
        {
          await MainActor.run {
            onDismiss()

            // Navigate to conversation
            appState.navigationManager.navigate(
              to: .conversation(convoId),
              in: 4
            )
            appState.navigationManager.tabSelection?(4)
          }

          // Send message in background
          let strongRef = ComAtprotoRepoStrongRef(uri: post.uri, cid: post.cid)
          let recordEmbed = AppBskyEmbedRecord(record: strongRef)
          let embed = ChatBskyConvoDefs.MessageInputEmbedUnion.appBskyEmbedRecord(recordEmbed)

          _ = await appState.chatManager.sendMessage(
            convoId: convoId,
            text: messageText,
            embed: embed
          )
        } else {
          await MainActor.run {
            isSending = false
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
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
      Button(action: action) {
        HStack(spacing: 14) {
          // Avatar
          Group {
            if let avatarURL = avatarURL,
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
            } else {
              Circle()
                .fill(.quaternary)
                .overlay {
                  Text(title.prefix(1))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                }
            }
          }
          .frame(width: 48, height: 48)
          .clipShape(Circle())

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

  // MARK: - MLS Chat Selection View

  @available(iOS 18.0, *)
  struct MLSChatSelectionView: View {
    let post: AppBskyFeedDefs.PostView
    let appState: AppState
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var messageText = ""
    @State private var selectedConversation: MLSConversationModel? = nil
    @State private var isSending = false
    @State private var isLoading = true
    @State private var conversations: [MLSConversationModel] = []
    @State private var conversationParticipants: [String: [MLSParticipantViewModel]] = [:]
    @State private var showingPostPreview = false
    @FocusState private var isMessageFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private let logger = Logger(subsystem: "blue.catbird", category: "ShareToMLSChat")

    var body: some View {
      NavigationStack {
        ZStack {
          Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme)
            .ignoresSafeArea()

          VStack(spacing: 0) {
            // Modern search bar
            searchBar
              .padding(.horizontal)
              .padding(.top, 8)

            // Selected conversation chip
            if let conversation = selectedConversation {
              selectedConversationView(conversation)
                .transition(
                  .asymmetric(
                    insertion: .push(from: .bottom).combined(with: .opacity),
                    removal: .push(from: .top).combined(with: .opacity)
                  ))
            }

            // Message composer
            if selectedConversation != nil {
              messageComposer
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Conversations list
            conversationsList
          }
        }
        .navigationTitle("Share to Secure Chat")
        #if os(iOS)
          .toolbarTitleDisplayMode(.inline)
        #endif
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark") {
              onDismiss()
            }
            .disabled(isSending)
          }

          ToolbarItem(placement: .primaryAction) {
            if selectedConversation != nil {
              sendButton
            }
          }
        }
        .sheet(isPresented: $showingPostPreview) {
          PostPreviewSheet(post: post)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .animation(.smooth(duration: 0.3), value: selectedConversation)
        .animation(.smooth(duration: 0.2), value: searchText)
      }
      .task {
        await loadMLSConversations()
      }
    }

    // MARK: - View Components

    private var searchBar: some View {
      HStack(spacing: 12) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .fontWeight(.medium)

        TextField("Search secure conversations", text: $searchText)
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

    private func selectedConversationView(_ conversation: MLSConversationModel) -> some View {
      let participants = conversationParticipants[conversation.conversationID] ?? []
      let displayTitle = conversation.title ?? participantsDisplayName(participants)

      return HStack(spacing: 12) {
        // Group avatar
        MLSGroupAvatarView(
          participants: participants,
          size: 32
        )

        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            Text(displayTitle)
              .font(.subheadline.weight(.medium))
            Image(systemName: "lock.shield.fill")
              .font(.system(size: 10))
              .foregroundColor(.green)
          }
          Text("\(participants.count) members")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          withAnimation(.smooth(duration: 0.2)) {
            selectedConversation = nil
            isMessageFieldFocused = false
          }
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .imageScale(.medium)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
      .padding(.horizontal)
      .padding(.vertical, 8)
    }

    private var messageComposer: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Message")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)

          Spacer()

          // Post preview button
          Button {
            showingPostPreview = true
          } label: {
            Label("Preview", systemImage: "eye")
              .font(.caption.weight(.medium))
              .foregroundStyle(.accent)
          }

          Text("\(messageText.count)/1000")
            .font(.caption2)
            .foregroundStyle(
              messageText.count > 900
                ? .red
                : Color.dynamicTertiaryBackground(appState.themeManager, currentScheme: colorScheme)
            )
            .contentTransition(.numericText())
        }

        TextEditor(text: $messageText)
          .focused($isMessageFieldFocused)
          .scrollContentBackground(.hidden)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.regularMaterial, in: .rect(cornerRadius: 12))
          .frame(minHeight: 80, maxHeight: 120)
          .onChange(of: messageText) { _, newValue in
            if newValue.count > 1000 {
              messageText = String(newValue.prefix(1000))
            }
          }

        Text("The post will be attached as an end-to-end encrypted embed")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal)
      .padding(.bottom, 8)
    }

    private var sendButton: some View {
      Button {
        sendMessage()
      } label: {
        if isSending {
          ProgressView()
            .controlSize(.small)
        } else {
          Text("Send")
            .fontWeight(.semibold)
        }
      }
      .disabled(isSending)
    }

    private var conversationsList: some View {
      ScrollView {
        LazyVStack(spacing: 0) {
          if isLoading {
            ProgressView("Loading secure conversations...")
              .padding(.vertical, 60)
          } else if filteredConversations.isEmpty {
            emptyState
          } else {
            ForEach(filteredConversations) { conversation in
              let participants = conversationParticipants[conversation.conversationID] ?? []
              MLSConversationSelectionRow(
                conversation: conversation,
                participants: participants,
                isSelected: selectedConversation?.conversationID == conversation.conversationID,
                showDivider: conversation.conversationID != filteredConversations.last?.conversationID
              ) {
                selectConversation(conversation)
              }
            }
          }
        }
        .animation(.default, value: filteredConversations.map { $0.conversationID })
      }
      .scrollDismissesKeyboard(.interactively)
    }

    private var emptyState: some View {
      ContentUnavailableView {
        Label("No Secure Conversations", systemImage: "lock.shield")
      } description: {
        Text(
          searchText.isEmpty
            ? "Start a secure conversation first to share posts"
            : "No secure conversations found for '\(searchText)'"
        )
      }
      .padding(.vertical, 60)
    }

    // MARK: - Helper Methods

    private var filteredConversations: [MLSConversationModel] {
      if searchText.isEmpty {
        return conversations
      }

      return conversations.filter { conversation in
        // Search by conversation title
        if let title = conversation.title, title.localizedCaseInsensitiveContains(searchText) {
          return true
        }

        // Search by participant names
        if let participants = conversationParticipants[conversation.conversationID] {
          for participant in participants {
            if participant.handle.localizedCaseInsensitiveContains(searchText) {
              return true
            }
            if let displayName = participant.displayName,
               displayName.localizedCaseInsensitiveContains(searchText) {
              return true
            }
          }
        }

        return false
      }
    }

    private func selectConversation(_ conversation: MLSConversationModel) {
      withAnimation(.smooth(duration: 0.3)) {
        selectedConversation = conversation
        searchText = ""
        isMessageFieldFocused = true
      }
    }

    private func participantsDisplayName(_ participants: [MLSParticipantViewModel]) -> String {
      if participants.isEmpty {
        return "Secure Chat"
      }

      let names = participants.prefix(3).compactMap { $0.displayName ?? $0.handle }
      if names.isEmpty {
        return "Secure Chat"
      }

      if participants.count > 3 {
        return names.joined(separator: ", ") + " +\(participants.count - 3)"
      }

      return names.joined(separator: ", ")
    }

    private func loadMLSConversations() async {
      isLoading = true
      defer { isLoading = false }

       let userDID = appState.userDID

      do {
        // Use smart routing - auto-routes to lightweight Queue if needed
        let (loadedConversations, membersByConvoID) = try await MLSStorage.shared.fetchConversationsWithMembersUsingSmartRouting(
          currentUserDID: userDID
        )

        conversations = loadedConversations
        logger.info("Loaded \(self.conversations.count) MLS conversations for sharing")

        // Load participants (no additional DB queries needed)
        await loadConversationParticipants(membersByConvoID: membersByConvoID, userDID: userDID)

      } catch {
        logger.error("Failed to load MLS conversations: \(error)")
        conversations = []
      }
    }

    private func loadConversationParticipants(membersByConvoID: [String: [MLSMemberModel]], userDID: String) async {
      var allDIDs = Set<String>()

      // Collect DIDs for profile fetching (no DB queries - data already loaded)
      for (_, members) in membersByConvoID {
        for member in members {
          allDIDs.insert(member.did)
        }
      }

      // Fetch profiles from Bluesky (network call, not DB)
      var profilesByDID: [String: MLSProfileEnricher.ProfileData] = [:]
      if let client = appState.atProtoClient {
        profilesByDID = await fetchProfilesForDIDs(Array(allDIDs), client: client)
      }

      // Convert members to participants with enriched profile data
      for (convoID, members) in membersByConvoID {
        let participants = members.map { member -> MLSParticipantViewModel in
          let profile = profilesByDID[member.did]
          return MLSParticipantViewModel(
            id: member.did,
            handle: profile?.handle ?? member.handle ?? member.did.split(separator: ":").last.map(String.init) ?? member.did,
            displayName: profile?.displayName ?? member.displayName,
            avatarURL: profile?.avatarURL
          )
        }
        conversationParticipants[convoID] = participants
      }
    }

    private func fetchProfilesForDIDs(_ dids: [String], client: ATProtoClient) async -> [String: MLSProfileEnricher.ProfileData] {
      var profilesByDID: [String: MLSProfileEnricher.ProfileData] = [:]

      let batchSize = 25
      let batches = stride(from: 0, to: dids.count, by: batchSize).map {
        Array(dids[$0..<min($0 + batchSize, dids.count)])
      }

      for batch in batches {
        do {
          let actors = try batch.map { try ATIdentifier(string: $0) }
          let params = AppBskyActorGetProfiles.Parameters(actors: actors)
          let (code, response) = try await client.app.bsky.actor.getProfiles(input: params)

          guard code >= 200 && code < 300, let profiles = response?.profiles else {
            continue
          }

          for profile in profiles {
            let profileData = MLSProfileEnricher.ProfileData(from: profile)
            profilesByDID[profileData.did] = profileData
          }

        } catch {
          logger.error("Failed to fetch profile batch: \(error)")
        }
      }

      return profilesByDID
    }

    private func sendMessage() {
      guard let conversation = selectedConversation else { return }

      isSending = true

      Task {
        do {
          // Create the post embed for MLS
          let postEmbed = createPostEmbed(from: post)

          // Get MLS conversation manager
          guard let manager = await appState.getMLSConversationManager() else {
            throw NSError(domain: "MLSChat", code: -1, userInfo: [NSLocalizedDescriptionKey: "MLS service not available"])
          }

          // Send the message with embed
          let (messageId, _, _, _) = try await manager.sendMessage(
            convoId: conversation.conversationID,
            plaintext: messageText.isEmpty ? "📝 Shared a post" : messageText,
            embed: .post(postEmbed)
          )

          logger.info("Sent post to MLS conversation \(conversation.conversationID): \(messageId)")

          await MainActor.run {
            onDismiss()

            // Navigate to the MLS conversation
            appState.navigationManager.navigate(
              to: .mlsConversation(conversation.conversationID),
              in: 4
            )
            appState.navigationManager.tabSelection?(4)
          }

        } catch {
          logger.error("Failed to send post to MLS conversation: \(error)")
          await MainActor.run {
            isSending = false
          }
        }
      }
    }

    private func createPostEmbed(from post: AppBskyFeedDefs.PostView) -> MLSPostEmbed {
      // Extract post text
      let postText: String
      if case let .knownType(record) = post.record,
         let feedPost = record as? AppBskyFeedPost {
        postText = feedPost.text
      } else {
        postText = ""
      }

      // Extract images if present
      var images: [MLSPostImage]?
      if let embed = post.embed {
        switch embed {
        case .appBskyEmbedImagesView(let imagesView):
          let mappedImages = imagesView.images.compactMap { imageView -> MLSPostImage? in
            guard let fullsize = imageView.fullsize.url, let thumb = imageView.thumb.url else {
              return nil
            }
            return MLSPostImage(
              thumb: thumb,
              fullsize: fullsize,
              alt: imageView.alt
            )
          }
          images = mappedImages.isEmpty ? nil : mappedImages
        default:
          break
        }
      }

      return MLSPostEmbed(
        uri: post.uri.uriString(),
        cid: post.cid.string,
        authorDid: post.author.did.description,
        authorHandle: post.author.handle.description,
        authorDisplayName: post.author.displayName,
        authorAvatar: post.author.finalAvatarURL(),
        text: postText,
        createdAt: post.indexedAt.date,
        likeCount: post.likeCount,
        replyCount: post.replyCount,
        repostCount: post.repostCount,
        images: images
      )
    }
  }

  // MARK: - MLS Conversation Selection Row

  @available(iOS 18.0, *)
  struct MLSConversationSelectionRow: View {
    let conversation: MLSConversationModel
    let participants: [MLSParticipantViewModel]
    let isSelected: Bool
    let showDivider: Bool
    let action: () -> Void

    @State private var isPressed = false

    private var displayTitle: String {
      if let title = conversation.title, !title.isEmpty {
        return title
      }

      // Build title from participants
      if participants.isEmpty {
        return "Secure Chat"
      }

      let names = participants.prefix(2).compactMap { $0.displayName ?? $0.handle }
      if names.isEmpty {
        return "Secure Chat"
      }

      if participants.count > 2 {
        return names.joined(separator: ", ") + " +\(participants.count - 2)"
      }

      return names.joined(separator: ", ")
    }

    var body: some View {
      Button(action: action) {
        HStack(spacing: 14) {
          // Group avatar
          MLSGroupAvatarView(
            participants: participants,
            size: 48
          )

          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
              Text(displayTitle)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

              // E2EE indicator
              Image(systemName: "lock.shield.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)
            }

            Text("\(participants.count) members • Epoch \(conversation.epoch)")
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

#else
  import Petrel
  import SwiftUI

  // macOS stubs for sharing functionality
  class ShareToChatActivity {
    init(post: AppBskyFeedDefs.PostView, appState: AppState) {
      // macOS stub - sharing features not available
    }
  }

  class ShareToMLSChatActivity {
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
