#if os(macOS)
import CatbirdMLSCore
import OSLog
import Petrel
import SwiftUI

// MARK: - macOS Chat Sidebar

/// Unified conversation list sidebar for macOS. Shows both Bluesky DM and MLS
/// conversations sorted by last activity, with search, context menus, and message requests.
@available(macOS 13.0, *)
struct MacOSChatSidebar: View {
  @Environment(AppState.self) private var appState
  @Bindable var coordinator: UnifiedChatCoordinator
  @Binding var selectedConvoId: String?
  @Binding var searchText: String

  var onNewConversation: () -> Void = {}

  private let logger = Logger(subsystem: "blue.catbird", category: "MacOSChatSidebar")

  var body: some View {
    List(selection: $selectedConvoId) {
      if !searchText.isEmpty {
        searchResultsContent
      } else {
        conversationListContent
      }
    }
    .listStyle(.sidebar)
    .searchable(text: $searchText, placement: .sidebar, prompt: "Search")
    .onChange(of: searchText) { _, newValue in
      appState.chatManager.searchLocal(searchTerm: newValue, currentUserDID: appState.userDID)
    }
    .overlay {
      if coordinator.conversations.isEmpty && !appState.chatManager.loadingConversations {
        ContentUnavailableView {
          Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
        } description: {
          Text("Start a conversation to see it here.")
        }
      }
    }
    .navigationTitle("Messages")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        MessageRequestsButton()
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          onNewConversation()
        } label: {
          Image(systemName: "plus")
        }
        .keyboardShortcut("n", modifiers: .command)
        .help("New Conversation")
      }
    }
  }

  // MARK: - Conversation List

  @ViewBuilder
  private var conversationListContent: some View {
    ForEach(coordinator.conversations) { item in
      MacOSUnifiedConversationRow(item: item, currentUserDID: appState.userDID)
        .tag(item.id)
        .contextMenu {
          conversationContextMenu(for: item)
        }
    }

    if shouldShowPagination {
      ProgressView()
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onAppear {
          Task {
            await appState.chatManager.loadConversations(refresh: false)
          }
        }
    }
  }

  // MARK: - Search Results

  @ViewBuilder
  private var searchResultsContent: some View {
    if !appState.chatManager.filteredProfiles.isEmpty {
      Section("Contacts") {
        ForEach(appState.chatManager.filteredProfiles, id: \.did) { profile in
          Button {
            startConversation(with: profile)
          } label: {
            HStack(spacing: 8) {
              ChatProfileAvatarView(profile: profile, size: 32)
              VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                  Text(profile.displayName ?? profile.handle.description)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                  if let badgeKind = VerificationBadge.kind(
                    for: profile.verification,
                    did: profile.did
                  ) {
                    VerificationBadgeView(kind: badgeKind)
                      .font(.caption)
                  }
                }
                Text("@\(profile.handle.description)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            }
          }
          .buttonStyle(.plain)
        }
      }
    }

    if !appState.chatManager.filteredConversations.isEmpty {
      Section("Conversations") {
        ForEach(appState.chatManager.filteredConversations) { convo in
          MacOSUnifiedConversationRow(
            item: .bluesky(convo),
            currentUserDID: appState.userDID
          )
          .tag(convo.id)
          .contextMenu {
            conversationContextMenu(for: .bluesky(convo))
          }
        }
      }
    }
  }

  // MARK: - Context Menus

  @ViewBuilder
  private func conversationContextMenu(for item: UnifiedConversation) -> some View {
    switch item {
    case .bluesky(let convo):
      Button("Mark as Read") {
        Task { await appState.chatManager.markConversationAsRead(convoId: convo.id) }
      }
      if convo.muted {
        Button("Unmute") {
          Task { await appState.chatManager.unmuteConversation(convoId: convo.id) }
        }
      } else {
        Button("Mute") {
          Task { await appState.chatManager.muteConversation(convoId: convo.id) }
        }
      }
      Divider()
      Button("Leave Conversation", role: .destructive) {
        Task { await appState.chatManager.leaveConversation(convoId: convo.id) }
      }

    case .mls(let convo, _, _, _, _, _):
      if convo.isMuted {
        Button("Unmute") {
          toggleMLSMute(convo)
        }
      } else {
        Button("Mute") {
          toggleMLSMute(convo)
        }
      }
      Divider()
      Button("Leave Group", role: .destructive) {
        leaveMLSConversation(convo)
      }
    }
  }

  // MARK: - Helpers

  private var shouldShowPagination: Bool {
    !appState.chatManager.acceptedConversations.isEmpty
      && appState.chatManager.conversationsCursor != nil
      && !appState.chatManager.loadingConversations
  }

  private func startConversation(with profile: ChatBskyActorDefs.ProfileViewBasic) {
    Task {
      if let convoId = await appState.chatManager.startConversationWith(userDID: profile.did.didString()) {
        await MainActor.run { selectedConvoId = convoId }
      }
    }
  }

  private func leaveMLSConversation(_ conversation: MLSConversationModel) {
    let convoID = conversation.conversationID
    let userDID = appState.userDID
    Task {
      guard let mlsCoordinator = await appState.getOrOpenMLSCoordinator() else { return }
      do {
        try? await mlsCoordinator.removeGroupMember(
          actorRole: .admin,
          conversationId: convoID,
          targetDid: userDID
        )
        await MainActor.run {
          var updatedState = coordinator.mlsState
          updatedState.conversations.removeAll { $0.conversationID == convoID }
          updatedState.participants.removeValue(forKey: convoID)
          updatedState.unreadCounts.removeValue(forKey: convoID)
          updatedState.lastMessages.removeValue(forKey: convoID)
          updatedState.memberChanges.removeValue(forKey: convoID)
          coordinator.mlsState = updatedState
          if selectedConvoId == convoID { selectedConvoId = nil }
          NotificationCenter.default.post(name: Notification.Name("MLSConversationLeft"), object: convoID)
        }
        appState.updateMLSUnreadCount()
      }
    }
  }

  private func toggleMLSMute(_ conversation: MLSConversationModel) {
    let convoID = conversation.conversationID
    let defaults = UserDefaults(suiteName: MLSAppGroupStorage.appGroupIdentifier) ?? .standard
    let muteKey = "mls.mutedUntil.\(appState.userDID.lowercased()).\(convoID)"
    if conversation.isMuted {
      defaults.removeObject(forKey: muteKey)
    } else {
      defaults.set(Date.distantFuture.timeIntervalSince1970, forKey: muteKey)
    }
    appState.stateInvalidationBus.notify(.mlsConversationListChanged)
  }
}
#endif
