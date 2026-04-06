#if os(macOS)
import CatbirdMLSCore
import GRDB
import OSLog
import Petrel
import SwiftUI

// MARK: - MLS List Change Observer

/// Bridges StateInvalidationBus MLS events to an AsyncStream
private final class MacOSMLSListChangeObserver: StateInvalidationSubscriber {
  let continuation: AsyncStream<Void>.Continuation

  init(continuation: AsyncStream<Void>.Continuation) {
    self.continuation = continuation
  }

  func isInterestedIn(_ event: StateInvalidationEvent) -> Bool {
    if case .mlsConversationListChanged = event { return true }
    return false
  }

  func handleStateInvalidation(_ event: StateInvalidationEvent) async {
    continuation.yield()
  }
}

// MARK: - macOS Chat Content View

/// Full-featured macOS chat view that merges Bluesky DMs and MLS encrypted
/// conversations into a unified sidebar + detail NavigationSplitView.
@available(macOS 13.0, *)
struct MacOSChatContentView: View {
  @Environment(AppState.self) private var appState

  @State private var selectedConvoId: String?
  @State private var searchText = ""
  @State private var coordinator = UnifiedChatCoordinator()
  @State private var mlsPollingTask: Task<Void, Never>?
  @State private var mlsPollCycleCount: Int = 0
  @State private var showingNewMessageSheet = false
  @State private var isShowingErrorAlert = false
  @State private var lastErrorMessage: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "MacOSChatTab")

  /// Per-account MLS chat enabled state
  private var mlsChatEnabledForCurrentAccount: Bool {
    ExperimentalSettings.shared.isMLSChatEnabled(for: appState.userDID)
  }

  var body: some View {
    NavigationSplitView {
      MacOSChatSidebar(
        coordinator: coordinator,
        selectedConvoId: $selectedConvoId,
        searchText: $searchText,
        onNewConversation: { showingNewMessageSheet = true }
      )
      .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
    } detail: {
      MacOSChatDetailRouter(
        coordinator: coordinator,
        selectedConvoId: selectedConvoId,
        selectedTab: .constant(4)
      )
    }
    .navigationSubtitle(selectedConversationSubtitle)
    .onAppear(perform: handleOnAppear)
    .onDisappear(perform: handleOnDisappear)
    .onChange(of: appState.chatManager.acceptedConversations) { _, newValue in
      coordinator.blueskyConversations = newValue
    }
    .onChange(of: appState.navigationManager.targetConversationId) { _, newValue in
      if let convoId = newValue, convoId != selectedConvoId {
        selectedConvoId = convoId
        appState.navigationManager.targetConversationId = nil
      }
    }
    .onChange(of: appState.navigationManager.targetMLSConversationId) { _, newValue in
      if let convoId = newValue, convoId != selectedConvoId {
        selectedConvoId = convoId
        appState.navigationManager.targetMLSConversationId = nil
      }
    }
    .onChange(of: appState.chatManager.errorState) { oldError, newError in
      handleErrorStateChange(oldError: oldError, newError: newError)
    }
    .alert(isPresented: $isShowingErrorAlert) {
      Alert(
        title: Text("Chat Error"),
        message: Text(lastErrorMessage ?? "An unknown error occurred."),
        dismissButton: .default(Text("OK")) {
          appState.chatManager.errorState = nil
          lastErrorMessage = nil
        }
      )
    }
    .onKeyPress(.escape) {
      if selectedConvoId != nil {
        selectedConvoId = nil
        return .handled
      }
      return .ignored
    }
    .sheet(isPresented: $showingNewMessageSheet) {
      NewConversationView()
        .frame(minWidth: 450, minHeight: 500)
    }
  }

  // MARK: - Event Handlers

  private func handleOnAppear() {
    // Bluesky DMs
    Task {
      if appState.chatManager.acceptedConversations.isEmpty && !appState.chatManager.loadingConversations {
        await appState.chatManager.loadConversations(refresh: true)
      }
    }
    appState.chatManager.startConversationsPolling()
    coordinator.blueskyConversations = appState.chatManager.acceptedConversations

    // MLS
    coordinator.mlsEnabled = mlsChatEnabledForCurrentAccount
    if mlsChatEnabledForCurrentAccount {
      Task { await loadMLSConversations() }
      startMLSPolling()
    }
  }

  private func handleOnDisappear() {
    stopMLSPolling()
  }

  private func handleErrorStateChange(oldError: ChatManager.ChatError?, newError: ChatManager.ChatError?) {
    if let error = newError, !isShowingErrorAlert {
      let errorMessage = error.localizedDescription
      if lastErrorMessage != errorMessage {
        lastErrorMessage = errorMessage
        isShowingErrorAlert = true
      }
    } else if newError == nil {
      isShowingErrorAlert = false
      lastErrorMessage = nil
    }
  }

  // MARK: - MLS Data Loading

  @MainActor
  private func loadMLSConversations() async {
    guard mlsChatEnabledForCurrentAccount else {
      coordinator.mlsEnabled = false
      return
    }
    coordinator.mlsEnabled = true

    let userDID = appState.userDID

    do {
      let (loadedConversations, membersByConvoID) = try await MLSStorage.shared
        .fetchConversationsWithMembersUsingSmartRouting(currentUserDID: userDID)

      let acceptedConversations = loadedConversations.filter { $0.requestState != .pendingInbound }

      let unreadCounts = try await MLSGRDBManager.shared.read(for: userDID) { db in
        try MLSStorageHelpers.getUnreadCountsForAllConversationsSync(from: db, currentUserDID: userDID)
      }

      let (lastMessages, latestActivityByConvo) = try await MLSGRDBManager.shared.read(for: userDID) { db -> ([String: MLSLastMessagePreview], [String: Date]) in
        var previews: [String: MLSLastMessagePreview] = [:]
        var latestActivity: [String: Date] = [:]
        for conversation in acceptedConversations {
          let convoID = conversation.conversationID
          let recentMessages = try MLSMessageModel
            .filter(MLSMessageModel.Columns.conversationID == convoID)
            .filter(MLSMessageModel.Columns.currentUserDID == userDID)
            .order(MLSMessageModel.Columns.timestamp.desc)
            .limit(20)
            .fetchAll(db)

          if let newest = recentMessages.first {
            latestActivity[convoID] = newest.timestamp
          }

          for message in recentMessages {
            if message.processingError != nil {
              let text = message.parsedPayload?.text ?? ""
              if text.isEmpty || text.contains("Message unavailable")
                || text.contains("Decryption Failed") || text.contains("Self-sent message") {
                continue
              }
            }
            if let payload = message.parsedPayload {
              switch payload.messageType {
              case .text, .system, nil:
                if let plaintext = payload.text, !plaintext.isEmpty {
                  previews[convoID] = MLSLastMessagePreview(senderDID: message.senderID, text: plaintext)
                } else if case .some(.image(_)) = payload.embed {
                  previews[convoID] = MLSLastMessagePreview(senderDID: message.senderID, text: "Sent a photo")
                } else {
                  continue
                }
              case .reaction:
                previews[convoID] = MLSLastMessagePreview(senderDID: message.senderID, text: "Reacted to a message")
              case .readReceipt, .typing, .adminRoster, .adminAction, .deliveryAck, .recoveryRequest:
                continue
              }
            } else {
              continue
            }
            break
          }
        }
        return (previews, latestActivity)
      }

      let sortedConversations = acceptedConversations.sorted { lhs, rhs in
        let lhsDate = latestActivityByConvo[lhs.conversationID] ?? lhs.createdAt
        let rhsDate = latestActivityByConvo[rhs.conversationID] ?? rhs.createdAt
        return lhsDate > rhsDate
      }

      // Build participants from DB-cached profiles
      var participants: [String: [MLSParticipantViewModel]] = [:]
      var dbProfiles: [MLSProfileEnricher.ProfileData] = []
      for members in membersByConvoID.values {
        for member in members where member.handle != nil || member.displayName != nil {
          dbProfiles.append(MLSProfileEnricher.ProfileData(
            did: member.did, handle: member.handle ?? "",
            displayName: member.displayName, avatarURL: nil
          ))
        }
      }
      await appState.mlsProfileEnricher.seedFromDatabase(dbProfiles)

      let dbProfilesByDID = Dictionary(
        dbProfiles.map { (MLSProfileEnricher.canonicalDID($0.did), $0) },
        uniquingKeysWith: { first, _ in first }
      )
      for (convoID, members) in membersByConvoID {
        participants[convoID] = members.map { member in
          let canonicalDID = MLSProfileEnricher.canonicalDID(member.did)
          let profile = dbProfilesByDID[canonicalDID]
          return MLSParticipantViewModel(
            id: member.did,
            handle: profile?.handle ?? member.handle ?? member.did.split(separator: ":").last.map(String.init) ?? member.did,
            displayName: profile?.displayName ?? member.displayName,
            avatarURL: profile?.avatarURL
          )
        }
      }

      // Single state assignment to avoid flicker
      var newState = MLSConversationListState()
      newState.conversations = sortedConversations
      newState.participants = participants
      newState.unreadCounts = unreadCounts
      newState.lastMessages = lastMessages
      newState.latestActivity = latestActivityByConvo
      newState.isLoading = false
      coordinator.mlsState = newState

      // Background: enrich with network profiles
      Task {
        await enrichMLSParticipantsFromNetwork(membersByConvoID: membersByConvoID, userDID: userDID)
      }
    } catch {
      logger.error("Failed to load MLS conversations: \(error)")
    }
  }

  private func enrichMLSParticipantsFromNetwork(membersByConvoID: [String: [MLSMemberModel]], userDID: String) async {
    var allDIDs = Set<String>()
    for (_, members) in membersByConvoID {
      for member in members { allDIDs.insert(member.did) }
    }

    guard let client = appState.atProtoClient else { return }
    let profilesByDID = await appState.mlsProfileEnricher.ensureProfiles(
      for: Array(allDIDs), using: client, currentUserDID: userDID
    )
    guard !profilesByDID.isEmpty else { return }

    var enrichedParticipants: [String: [MLSParticipantViewModel]] = [:]
    for (convoID, members) in membersByConvoID {
      enrichedParticipants[convoID] = members.map { member in
        let canonicalDID = MLSProfileEnricher.canonicalDID(member.did)
        let profile = profilesByDID[canonicalDID] ?? profilesByDID[member.did]
        return MLSParticipantViewModel(
          id: member.did,
          handle: profile?.handle ?? member.handle ?? member.did.split(separator: ":").last.map(String.init) ?? member.did,
          displayName: profile?.displayName ?? member.displayName,
          avatarURL: profile?.avatarURL
        )
      }
    }

    let existingParticipants = coordinator.mlsState.participants
    let changed = enrichedParticipants.contains { key, val in
      guard let existing = existingParticipants[key] else { return true }
      return existing != val
    }
    if changed {
      var updatedState = coordinator.mlsState
      updatedState.participants = enrichedParticipants
      coordinator.mlsState = updatedState
    }
  }

  // MARK: - MLS Polling

  private func startMLSPolling() {
    mlsPollingTask?.cancel()
    mlsPollingTask = Task {
      let bus = appState.stateInvalidationBus

      let stream = AsyncStream<Void> { continuation in
        let observer = MacOSMLSListChangeObserver(continuation: continuation)
        bus.subscribe(observer)
        continuation.onTermination = { _ in
          bus.unsubscribe(observer)
        }
      }

      await withTaskGroup(of: Void.self) { group in
        group.addTask {
          for await _ in stream {
            guard !Task.isCancelled else { break }
            await self.loadMLSConversations()
          }
        }
        group.addTask {
          var cycleCount = 0
          while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { break }
            await self.loadMLSConversations()
            cycleCount += 1
            if cycleCount % 5 == 0 {
              let userDID = self.appState.userDID
              Task.detached(priority: .utility) {
                try? await MLSGRDBManager.shared.checkpointDatabase(for: userDID)
              }
            }
          }
        }
      }
    }
  }

  private func stopMLSPolling() {
    mlsPollingTask?.cancel()
    mlsPollingTask = nil
  }

  // MARK: - Window Subtitle

  private var selectedConversationSubtitle: String {
    guard let convoId = selectedConvoId,
          let item = coordinator.conversations.first(where: { $0.id == convoId }) else {
      return ""
    }
    switch item {
    case .bluesky(let convo):
      let otherMembers = convo.members.filter { $0.did.description != appState.userDID }
      return otherMembers.first?.displayName ?? otherMembers.first?.handle.description ?? ""
    case .mls(let convo, let participants, _, _, _, _):
      if let title = convo.title, !title.isEmpty { return title }
      let others = participants.filter { $0.id != appState.userDID }
      return others.prefix(2).map { $0.displayName ?? $0.handle }.joined(separator: ", ")
    }
  }
}
#endif
