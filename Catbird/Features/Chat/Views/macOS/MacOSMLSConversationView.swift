#if os(macOS)
import CatbirdMLSCore
import GRDB
import OSLog
import Petrel
import SwiftUI

// MARK: - macOS MLS Conversation Detail

/// Displays an end-to-end encrypted MLS conversation on macOS using the shared
/// ChatListView for message rendering. Includes group info inspector and E2E badge.
@available(macOS 13.0, *)
struct MacOSMLSConversationView: View {
  @Environment(AppState.self) private var appState
  let conversationId: String

  @State private var dataSource: MLSConversationDataSource?
  @State private var viewModel: MLSConversationDetailViewModel?
  @State private var navigationPath = NavigationPath()
  @State private var showingEmojiPicker = false
  @State private var emojiPickerMessageID: String?
  @State private var showingGroupInfo = false
  @State private var isInitialized = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MacOSMLSConvo")

  var body: some View {
    Group {
      if let dataSource {
        ChatListView(
          dataSource: dataSource,
          navigationPath: $navigationPath,
          onRequestEmojiPicker: { messageID in
            emojiPickerMessageID = messageID
            showingEmojiPicker = true
          }
        )
      } else {
        ProgressView("Loading encrypted conversation...")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle(conversationTitle)
    .toolbar {
      ToolbarItem(placement: .principal) {
        HStack(spacing: 4) {
          Image(systemName: "lock.fill")
            .font(.system(size: 10))
            .foregroundStyle(.green)
          Text(conversationTitle)
            .font(.headline)
            .lineLimit(1)
          Text("E2EE")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.green)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          showingGroupInfo.toggle()
        } label: {
          Image(systemName: "info.circle")
        }
        .keyboardShortcut("i", modifiers: .command)
        .help("Group Info")
      }
    }
    .inspector(isPresented: $showingGroupInfo) {
      if let viewModel {
        MacOSGroupInfoInspector(
          viewModel: viewModel,
          conversationId: conversationId
        )
        .inspectorColumnWidth(min: 220, ideal: 280, max: 360)
      }
    }
    .task {
      await initializeConversation()
    }
    .onAppear {
      appState.chatHeartbeatManager.viewAppeared()
    }
    .onDisappear {
      appState.chatHeartbeatManager.viewDisappeared()
    }
    .customEmojiPicker(isPresented: $showingEmojiPicker) { emoji in
      guard let messageID = emojiPickerMessageID else { return }
      dataSource?.addReaction(messageID: messageID, emoji: emoji)
      emojiPickerMessageID = nil
    }
  }

  // MARK: - Initialization

  @MainActor
  private func initializeConversation() async {
    guard !isInitialized else { return }
    isInitialized = true

    guard let manager = await appState.getMLSConversationManager(timeout: 15.0) else {
      logger.error("Failed to get MLS conversation manager")
      return
    }

    let newViewModel = MLSConversationDetailViewModel(
      conversationId: conversationId,
      database: manager.database,
      apiClient: manager.apiClient,
      conversationManager: manager
    )
    viewModel = newViewModel

    dataSource = MLSConversationDataSource(
      conversationId: conversationId,
      currentUserDID: appState.userDID,
      appState: appState
    )

    Task.detached(priority: .userInitiated) { [newViewModel] in
      await newViewModel.loadConversation()
    }
  }

  // MARK: - Title

  private var conversationTitle: String {
    if let conversation = viewModel?.conversation {
      return conversation.metadata?.name ?? "Group Chat"
    }
    return "Encrypted Chat"
  }
}

// MARK: - Group Info Inspector

/// Inspector panel showing group members, metadata, and admin actions.
@available(macOS 14.0, *)
struct MacOSGroupInfoInspector: View {
  @Environment(AppState.self) private var appState
  let viewModel: MLSConversationDetailViewModel
  let conversationId: String

  var body: some View {
    inspectorContent
      .listStyle(.sidebar)
      .navigationTitle("Group Info")
  }

  @ViewBuilder
  private var inspectorContent: some View {
    List {
      if let conversation = viewModel.conversation {
        groupInfoSection(conversation)
        membersSection(conversation)
      }
      encryptionSection
    }
  }

  @ViewBuilder
  private func groupInfoSection(_ conversation: BlueCatbirdMlsChatDefs.ConvoView) -> some View {
    Section("Group") {
      LabeledContent("Name", value: conversation.metadata?.name ?? "Unnamed Group")
      LabeledContent("Members", value: "\(conversation.members.count)")
      LabeledContent("Epoch", value: "\(conversation.epoch)")
    }
  }

  @ViewBuilder
  private func membersSection(_ conversation: BlueCatbirdMlsChatDefs.ConvoView) -> some View {
    Section("Members") {
      ForEach(conversation.members, id: \.did) { member in
        HStack {
          Circle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: 28, height: 28)
            .overlay {
              Text(String(member.did.description.suffix(4)))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white)
            }
          VStack(alignment: .leading) {
            Text(member.did.description)
              .font(.body)
              .lineLimit(1)
              .truncationMode(.middle)
            if member.isAdmin {
              Text("Admin")
                .font(.caption)
                .foregroundStyle(.orange)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var encryptionSection: some View {
    Section("Encryption") {
      Label("End-to-End Encrypted", systemImage: "lock.fill")
        .foregroundStyle(.green)
      if let conversation = viewModel.conversation {
        LabeledContent("Cipher Suite", value: "MLS 1.0")
        LabeledContent("Epoch", value: "\(conversation.epoch)")
      }
    }
  }
}
#endif
