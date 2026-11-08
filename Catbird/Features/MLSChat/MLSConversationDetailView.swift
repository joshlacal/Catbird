//
//  MLSConversationDetailView.swift
//  Catbird
//
//  Spaces-only clean-slate iOS MLS conversation detail view backed by
//  MLSClientCoordinator and UnifiedChatView.
//

import CatbirdMLSCore
import OSLog
import Petrel
import SwiftUI

#if os(iOS)

struct MLSConversationDetailView: View {
  let conversationId: String

  var body: some View {
    MLSRequestConversationGate(conversationID: conversationId) {
      MLSOrdinaryConversationDetailView(conversationId: conversationId)
    }
  }
}

struct MLSOrdinaryConversationDetailView: View {
  @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneContext
  @Environment(\.scenePhase) private var scenePhase

  let conversationId: String

  @State private var dataSource: MLSConversationDataSource?
  @State private var groupTitle: String?
  @State private var groupDescription: String = ""
  @State private var spaceURI: String?
  @State private var showingGroupInfo = false
  @State private var showingLabyrinthSettings = false
  @State private var removeMemberDIDInput = ""
  @State private var groupInfoError: String?

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationDetail")

  /// Shared Chat tab navigation path so tapping a profile or post inside UnifiedChatView
  /// pushes onto the Chat tab stack and fires onDisappear (clearing active-convo state per PR #54).
  private var chatNavigationPath: Binding<NavigationPath> {
    sceneContext.navigationManager.pathBinding(for: AppNavigationManager.chatTabIndex)
  }

  private var isChatTabActive: Bool {
    sceneContext.navigationManager.currentTabIndex == AppNavigationManager.chatTabIndex
  }

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
        ContentUnavailableView(
          "Conversation Unavailable",
          systemImage: "lock.slash",
          description: Text("This conversation identifier is not a valid canonical MLS chat ID.")
        )
      } else if let dataSource {
        UnifiedChatView(
          dataSource: dataSource,
          navigationPath: chatNavigationPath,
          title: groupTitle ?? "Encrypted Chat"
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
        ProgressView("Opening encrypted chat…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button {
            showingGroupInfo = true
          } label: {
            Label("Chat Info & Metadata", systemImage: "info.circle")
          }
          Button {
            showingLabyrinthSettings = true
          } label: {
            Label("Encrypted History & Recovery", systemImage: "key.shield")
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("mlsConversation.menu")
      }
    }
    .sheet(isPresented: $showingGroupInfo) {
      groupInfoSheet
    }
    .sheet(isPresented: $showingLabyrinthSettings) {
      NavigationStack {
        LabyrinthSettingsAndRestoreView(coordinator: appState.mlsCoordinator)
      }
    }
    .task(id: "\(appState.userDID):\(conversationId)") {
      await initializeConversation()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        if isChatTabActive {
          MLSActiveConversationTracker.shared.setActive(conversationId)
        }
        Task { await dataSource?.loadMessages() }
      } else {
        MLSActiveConversationTracker.shared.setInactive(conversationId)
      }
    }
    .onChange(of: isChatTabActive) { _, active in
      if active {
        MLSActiveConversationTracker.shared.setActive(conversationId)
      } else {
        MLSActiveConversationTracker.shared.setInactive(conversationId)
      }
    }
    .onAppear {
      if isChatTabActive {
        MLSActiveConversationTracker.shared.setActive(conversationId)
      }
    }
    .onDisappear {
      MLSActiveConversationTracker.shared.setInactive(conversationId)
      dataSource?.stopObserving()
    }
  }

  private var groupInfoSheet: some View {
    NavigationStack {
      Form {
        Section("Encrypted Group Metadata") {
          TextField("Title", text: Binding(
            get: { groupTitle ?? "" },
            set: { groupTitle = $0.isEmpty ? nil : $0 }
          ))
          TextField("Description", text: $groupDescription, axis: .vertical)
            .lineLimit(2...5)
          Button("Save Metadata") {
            Task { await saveGroupMetadata() }
          }
        }

        if let spaceURI {
          Section("ATProto Space") {
            Text(verbatim: spaceURI)
              .font(.caption.monospaced())
              .textSelection(.enabled)
          }
        }

        Section("Admin Member Removal") {
          TextField("Member DID (did:plc:… or did:web:…)", text: $removeMemberDIDInput)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button("Remove Member (Admin Only)", role: .destructive) {
            Task { await removeMemberAsAdmin() }
          }
          .disabled(removeMemberDIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        if let groupInfoError {
          Section {
            Text(groupInfoError)
              .font(.footnote)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Chat Info")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { showingGroupInfo = false }
        }
      }
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
    await refreshMetadata()
  }

  @MainActor
  private func refreshMetadata() async {
    guard let coordinator = appState.mlsCoordinator else { return }
    if let metadata = try? await coordinator.getGroupMetadata(conversationId: conversationId) {
      groupTitle = metadata.title
      groupDescription = metadata.description ?? ""
    }
    if let convo = (try? await coordinator.listConversations(limit: 200))?.first(where: { $0.conversationId == conversationId }) {
      if groupTitle == nil {
        groupTitle = convo.title
      }
      spaceURI = convo.spaceUri
    }
  }

  @MainActor
  private func saveGroupMetadata() async {
    guard let coordinator = appState.mlsCoordinator else { return }
    do {
      let updated = try await coordinator.updateGroupMetadata(
        conversationId: conversationId,
        title: groupTitle ?? "",
        description: groupDescription
      )
      let updatedTitle = updated.title ?? ""
      groupTitle = updatedTitle.isEmpty ? nil : updatedTitle
      groupDescription = updated.description ?? ""
      groupInfoError = nil
    } catch {
      groupInfoError = error.localizedDescription
      logger.error("Failed to save group metadata: \(error.localizedDescription)")
    }
  }

  @MainActor
  private func removeMemberAsAdmin() async {
    guard let coordinator = appState.mlsCoordinator else { return }
    let targetDID = removeMemberDIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !targetDID.isEmpty else { return }
    do {
      try await coordinator.removeGroupMember(
        actorRole: .admin,
        conversationId: conversationId,
        targetDid: targetDID
      )
      removeMemberDIDInput = ""
      groupInfoError = nil
    } catch {
      groupInfoError = error.localizedDescription
    }
  }
}

#endif
