//
//  MacOSMLSConversationView.swift
//  Catbird
//
//  Spaces-only clean-slate macOS MLS conversation view backed by MLSClientCoordinator.
//

#if os(macOS)
import CatbirdMLSCore
import OSLog
import Petrel
import SwiftUI

struct MacOSMLSConversationView: View {
  let conversationId: String

  var body: some View {
    MLSRequestConversationGate(conversationID: conversationId) {
      MacOSMLSOrdinaryConversationView(conversationId: conversationId)
    }
  }
}

@available(macOS 13.0, *)
struct MacOSMLSOrdinaryConversationView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.scenePhase) private var scenePhase

  let conversationId: String

  @State private var dataSource: MLSConversationDataSource?
  @State private var navigationPath = NavigationPath()
  @State private var showingEmojiPicker = false
  @State private var emojiPickerMessageID: String?
  @State private var showingGroupInfo = false
  @State private var groupTitle: String = "Encrypted Chat"
  @State private var groupDescription: String = ""
  @State private var spaceURI: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "MacOSMLSConvo")

  var body: some View {
    Group {
      if let eligibility = appState.spacesEligibility, !eligibility.eligible {
        MLSSpacesRequiredGateView(
          eligibility: eligibility,
          onReauthorizeScopes: {
            Task { await appState.reauthorizeSpacesForMLS() }
          },
          onRefreshCheck: {
            try? await appState.initializeMLS()
          }
        )
      } else if !MLSConversationIdentityBoundary.isCanonicalStableID(conversationId) {
        ContentUnavailableView("Conversation unavailable", systemImage: "lock.slash")
      } else if let dataSource {
        ChatListView(
          dataSource: dataSource,
          navigationPath: $navigationPath,
          onRequestEmojiPicker: { messageID in
            emojiPickerMessageID = messageID
            showingEmojiPicker = true
          }
        )
        .overlay(alignment: .top) {
          if appState.mlsSyncIncompleteConversationIDs.contains(conversationId) {
            Label(
              "Couldn't update this conversation. Catbird will try again.",
              systemImage: "exclamationmark.arrow.triangle.2.circlepath"
            )
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .accessibilityIdentifier("mls-sync-incomplete-status")
          }
        }
      } else {
        ProgressView("Loading encrypted conversation…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle(groupTitle)
    .toolbar {
      ToolbarItem(placement: .principal) {
        HStack(spacing: 4) {
          Image(systemName: "lock.fill")
            .font(.system(size: 10))
            .foregroundStyle(.green)
          Text(groupTitle)
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
      Form {
        Section("Metadata") {
          TextField("Title", text: $groupTitle)
          TextField("Description", text: $groupDescription)
          Button("Save") {
            Task { await saveMetadata() }
          }
        }
        if let spaceURI {
          Section("ATProto Space") {
            Text(verbatim: spaceURI)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }
      }
      .inspectorColumnWidth(min: 220, ideal: 280, max: 360)
    }
    .task(id: "\(appState.userDID):\(conversationId)") {
      await initializeConversation()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        Task { await dataSource?.loadMessages() }
      }
    }
    .onDisappear {
      dataSource?.stopObserving()
    }
    .customEmojiPicker(isPresented: $showingEmojiPicker) { emoji in
      guard let messageID = emojiPickerMessageID else { return }
      dataSource?.addReaction(messageID: messageID, emoji: emoji)
      emojiPickerMessageID = nil
    }
  }

  @MainActor
  private func initializeConversation() async {
    dataSource?.stopObserving()
    let source = MLSConversationDataSource(
      conversationId: conversationId,
      currentUserDID: appState.userDID,
      appState: appState
    )
    dataSource = source
    await source.loadMessages()
    guard let coordinator = appState.mlsCoordinator else { return }
    if let meta = try? await coordinator.getGroupMetadata(conversationId: conversationId),
       let title = meta.title,
       !title.isEmpty
    {
      groupTitle = title
      groupDescription = meta.description ?? ""
    } else if let convo = (try? await coordinator.listConversations(limit: 200))?.first(where: { $0.conversationId == conversationId }) {
      groupTitle = convo.title ?? "Encrypted Chat"
      spaceURI = convo.spaceUri
    }
  }

  @MainActor
  private func saveMetadata() async {
    guard let coordinator = appState.mlsCoordinator else { return }
    _ = try? await coordinator.updateGroupMetadata(
      conversationId: conversationId,
      title: groupTitle,
      description: groupDescription
    )
  }
}
#endif
