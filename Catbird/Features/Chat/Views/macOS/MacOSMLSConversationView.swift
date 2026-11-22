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

private struct MacOSModerationTarget: Identifiable {
  let id = UUID()
  let did: String
  let handle: String?
  let displayName: String?
}

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
  @State private var groupTitle: String = String(
    localized: "Encrypted Chat",
    comment: "Fallback navigation title for an unnamed encrypted chat"
  )
  @State private var groupDescription: String = ""
  @State private var spaceURI: String?
  @State private var moderationDIDInput: String = ""
  @State private var reportTarget: MacOSModerationTarget?
  @State private var blockTarget: MacOSModerationTarget?
  @State private var showingReactionsSheet = false
  @State private var pendingCreationStatus: PendingGroupCreationStatus?
  @State private var isMutatingPendingCreation = false

  private let logger = Logger(subsystem: "blue.catbird", category: "MacOSMLSConvo")

  var body: some View {
    Group {
      if let eligibility = appState.spacesEligibility, !eligibility.eligible {
        MLSSpacesRequiredGateView(
          eligibility: eligibility,
          onReauthorizeScopes: { present in
            await appState.reauthorizeSpacesForMLS(present: present)
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
          VStack(spacing: 8) {
            if let pendingCreationStatus {
              MLSPendingGroupCreationBanner(
                status: pendingCreationStatus,
                isBusy: isMutatingPendingCreation,
                onRetry: {
                  Task {
                    guard let coordinator = appState.mlsCoordinator else { return }
                    isMutatingPendingCreation = true
                    defer { isMutatingPendingCreation = false }
                    _ = try? await coordinator.retryPendingGroupCreation(conversationId: conversationId)
                    self.pendingCreationStatus = try? await coordinator.pendingGroupCreationStatus(conversationId: conversationId)
                    await dataSource.loadMessages()
                    await appState.loadMLSConversations()
                  }
                },
                onCancel: {
                  Task {
                    guard let coordinator = appState.mlsCoordinator else { return }
                    isMutatingPendingCreation = true
                    defer { isMutatingPendingCreation = false }
                    _ = try? await coordinator.cancelPendingGroupCreation(conversationId: conversationId)
                    self.pendingCreationStatus = nil
                    await appState.loadMLSConversations()
                  }
                }
              )
              .padding(.horizontal, 12)
              .padding(.top, 8)
            }
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
          Text("E2EE", comment: "Short badge indicating end-to-end encryption")
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
        Section("Safety & Moderation") {
          let participants = dataSource?.participantDIDs ?? []
          ForEach(participants, id: \.self) { peerDID in
            let profile = dataSource?.enrichedProfilesSnapshot[MLSProfileEnricher.canonicalDID(peerDID)]
            let handleLabel = profile.map { "@\($0.handle)" }
            let label = profile?.displayName ?? handleLabel ?? peerDID
            HStack {
              Text(verbatim: label)
                .lineLimit(1)
              Spacer()
              Button("Report") {
                reportTarget = MacOSModerationTarget(did: peerDID, handle: profile?.handle, displayName: label)
              }
              Button("Block", role: .destructive) {
                blockTarget = MacOSModerationTarget(did: peerDID, handle: profile?.handle, displayName: profile?.displayName)
              }
            }
          }
          TextField("Participant DID", text: $moderationDIDInput)
          let trimmedDID = moderationDIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
          HStack {
            Button("Report DID") {
              reportTarget = MacOSModerationTarget(did: trimmedDID, handle: nil, displayName: trimmedDID)
            }
            .disabled(trimmedDID.isEmpty)
            Button("Block DID", role: .destructive) {
              blockTarget = MacOSModerationTarget(did: trimmedDID, handle: nil, displayName: trimmedDID)
            }
            .disabled(trimmedDID.isEmpty)
          }
          if dataSource?.messages.contains(where: { !$0.mlsReactions.isEmpty }) == true {
            Button("View Message Reactions") {
              showingReactionsSheet = true
            }
          }
          Button("Leave Conversation", role: .destructive) {
            Task {
              guard let coordinator = appState.mlsCoordinator else { return }
              do {
                _ = try await coordinator.leaveConversation(conversationId: conversationId)
                await appState.loadMLSConversations()
                showingGroupInfo = false
              } catch {
                logger.error("Failed to leave MLS conversation on macOS: \(error.localizedDescription)")
              }
            }
          }
        }
      }
      .inspectorColumnWidth(min: 220, ideal: 280, max: 360)
    }
    .sheet(item: $reportTarget) { target in
      MLSReportSpamSheet(
        conversationId: conversationId,
        reportedDid: target.did,
        reportedDisplayName: target.displayName ?? target.handle.map { "@\($0)" } ?? target.did
      )
      .environment(appState)
    }
    .sheet(item: $blockTarget) { target in
      BlockChatSenderSheet(
        senderDid: target.did,
        senderHandle: target.handle,
        senderDisplayName: target.displayName,
        conversationId: conversationId,
        onBlocked: {}
      )
      .environment(appState)
    }
    .sheet(isPresented: $showingReactionsSheet) {
      if let dataSource, let reactedMessage = dataSource.messages.last(where: { !$0.mlsReactions.isEmpty }) {
        MLSReactionDetailsSheet(
          reactions: reactedMessage.mlsReactions,
          participantProfiles: dataSource.enrichedProfilesSnapshot,
          currentUserDID: appState.userDID,
          onAddReaction: { emoji in
            dataSource.addReaction(messageID: reactedMessage.id, emoji: emoji)
          },
          onRemoveReaction: { emoji in
            dataSource.toggleReaction(messageID: reactedMessage.id, emoji: emoji)
          }
        )
      }
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
    pendingCreationStatus = try? await coordinator.pendingGroupCreationStatus(conversationId: conversationId)
    if let meta = try? await coordinator.getGroupMetadata(conversationId: conversationId),
       let title = meta.title,
       !title.isEmpty
    {
      groupTitle = title
      groupDescription = meta.description ?? ""
    } else if let convo = (try? await coordinator.listConversations(limit: 200))?.first(where: { $0.conversationId == conversationId }) {
      groupTitle = convo.title ?? String(
        localized: "Encrypted Chat",
        comment: "Fallback navigation title for an unnamed encrypted chat"
      )
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
