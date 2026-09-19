import CatbirdMLSCore
import SwiftUI

struct MLSDirectComposeView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var draft: MLSDirectComposeDraft
  @State private var busy = false
  @State private var status: String?
  let onConversation: (String) -> Void

  init(draft: MLSDirectComposeDraft, onConversation: @escaping (String) -> Void) {
    _draft = State(initialValue: draft)
    self.onConversation = onConversation
  }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 16) {
        Label("Encrypted message request", systemImage: "lock.fill").font(.headline)
        Text(draft.invitation == nil ? "Send one text introduction. You can continue chatting after it is accepted." : "The group invitation has already been sent. This optional encrypted note is a separate conversation.").foregroundStyle(.secondary)
        if draft.invitation != nil, let conversationID = draft.conversationID {
          Button("Open direct conversation") { onConversation(conversationID) }
          Text("Send the note only after this direct conversation is accepted. An uncertain note can be checked there.").font(.caption).foregroundStyle(.secondary)
        }
        TextEditor(text: $draft.text)
          .accessibilityLabel("Message composer")
          .accessibilityIdentifier("request-draft-composer")
          .disabled(busy || draft.submitted)
          .frame(minHeight: 160)
        if let status { Text(status).accessibilityIdentifier("request-draft-status") }
        if busy { ProgressView() }
        HStack {
          if draft.submitted && draft.conversationID == nil {
            Button("Cancel request", role: .destructive) { Task { await submit(cancel: true) } }
              .disabled(busy)
          }
          Spacer()
          Button(draft.invitation != nil && draft.conversationID != nil ? "Send note" : (draft.submitted ? "Retry" : "Send")) {
            Task {
              if draft.invitation != nil && draft.conversationID != nil { await sendExistingNote() }
              else { await submit(cancel: false) }
            }
          }
            .buttonStyle(.borderedProminent)
            .disabled(busy || draft.noteAttempted == true || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.text.utf8.count > 16_384)
            .accessibilityIdentifier("request-first-send")
        }
      }
      .padding()
      .navigationTitle("New Message")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { Task { await saveAndClose() } }.disabled(busy)
        }
      }
      .interactiveDismissDisabled()
      .onChange(of: appState.userDID) { _, _ in dismiss() }
      .task(id: draft.text) {
        guard !draft.submitted else { return }
        do {
          try await Task.sleep(for: .milliseconds(250))
          guard let database = appState.mlsDatabase, appState.userDID == draft.accountDID else { return }
          try await MLSDirectComposeDraftStore.save(draft, database: database)
        } catch is CancellationError { } catch { status = "Your draft could not be saved. Keep this window open and retry." }
      }
    }
  }

  @MainActor private func saveAndClose() async {
    guard appState.userDID == draft.accountDID, let database = appState.mlsDatabase else { dismiss(); return }
    do { try await MLSDirectComposeDraftStore.save(draft, database: database); dismiss() }
    catch { status = "Your draft could not be saved. Please try again." }
  }

  @MainActor private func sendExistingNote() async {
    guard !busy, draft.noteAttempted != true, let conversationID = draft.conversationID,
          let reference = draft.invitation, appState.userDID == draft.accountDID else { return }
    busy = true
    defer { busy = false }
    do {
      try MLSDirectComposeDraftStore.validateText(draft.text)
      guard let manager = await appState.getMLSConversationManager(),
            manager.currentUserDID == draft.accountDID, appState.userDID == draft.accountDID,
            try await MLSDirectRequestAccess.allowsOrdinaryEffects(manager: manager, conversationID: conversationID),
            let current = try await manager.getGroupInvitationReference(conversationId: reference.conversationId, recipientDid: draft.recipientDID),
            try MLSGroupInvitationReference(verified: current) == reference,
            appState.userDID == draft.accountDID, appState.mlsConversationManager === manager else {
        status = "The direct conversation must be accepted and the group invitation must still be current. Your note is saved."
        return
      }
      draft.noteAttempted = true
      try await MLSDirectComposeDraftStore.save(draft, database: manager.database)
      let messageID = try await manager.sendGroupInvitationNote(conversationId: conversationID, text: draft.text, reference: reference)
      guard appState.userDID == draft.accountDID, appState.mlsConversationManager === manager else { return }
      draft.noteMessageID = messageID
      try await MLSDirectComposeDraftStore.save(draft, database: manager.database)
      try await MLSDirectComposeDraftStore.archive(draft, database: manager.database)
      onConversation(conversationID)
      dismiss()
    } catch {
      guard appState.userDID == draft.accountDID else { return }
      status = draft.noteAttempted == true ? "The note may have been sent. Open the direct conversation to check; this attempt will not be sent again automatically." : "The note could not be prepared. Your text is saved."
    }
  }

  @MainActor private func submit(cancel: Bool) async {
    guard !busy, appState.userDID == draft.accountDID else { return }
    busy = true
    defer { busy = false }
    do {
      try MLSDirectComposeDraftStore.validateText(draft.text)
      guard let manager = await appState.getMLSConversationManager(),
            manager.currentUserDID == draft.accountDID, appState.userDID == draft.accountDID,
            !manager.isShuttingDown else { throw MLSDirectComposeDraftStore.Failure.accountChanged }
      draft.submitted = true
      try await MLSDirectComposeDraftStore.save(draft, database: manager.database)
      let result: DirectRequestOutcome
      if cancel {
        result = try await manager.cancelDirectRequest(draftId: draft.id.uuidString.lowercased())
      } else {
        result = try await manager.startDirectRequest(input: DirectRequestInput(
          draftId: draft.id.uuidString.lowercased(), recipientDid: draft.recipientDID,
          text: draft.text, invitation: draft.invitation?.requestReference))
      }
      guard appState.userDID == draft.accountDID, appState.mlsConversationManager === manager else { return }
      switch result {
      case .requestSent(let conversationId, _, _):
        draft.conversationID = conversationId
        try await MLSDirectComposeDraftStore.save(draft, database: manager.database)
        try await MLSDirectComposeDraftStore.archive(draft, database: manager.database)
        onConversation(conversationId)
        dismiss()
      case .existingDirect(let conversationId, _):
        draft.conversationID = conversationId
        try await MLSDirectComposeDraftStore.save(draft, database: manager.database)
        if draft.invitation != nil {
          status = "An existing direct conversation was found. Your note has not been sent. Use Send note after the conversation is accepted."
        } else {
          try await ChatDraftHandoff.shared.storeDurably(
            PendingChatDraft(conversationID: conversationId, text: draft.text),
            accountDID: draft.accountDID, database: manager.database)
          onConversation(conversationId)
          dismiss()
        }
      case .outcomeUnknown:
        status = "Checking whether your request was sent. Retry uses the same saved request."
      case .retryable:
        status = "The request could not finish yet. Your text is saved; try again."
      case .terminalNotPublished:
        status = "The request was not sent. Your draft is saved."
        if cancel { try await MLSDirectComposeDraftStore.archive(draft, database: manager.database); dismiss() }
      }
    } catch {
      guard appState.userDID == draft.accountDID else { return }
      status = "Unable to finish the request. Your saved request will be reused when you retry."
    }
  }
}

struct MLSDirectDraftPresentation: ViewModifier {
  @Environment(AppState.self) private var appState
  @State private var draft: MLSDirectComposeDraft?
  @State private var presentedAccount: String?
  @State private var presentedDatabase: MLSDatabase?

  func body(content: Content) -> some View {
    content
      .sheet(item: $draft, onDismiss: clear) { draft in
        MLSDirectComposeView(draft: draft) { conversationID in
          appState.navigationManager.targetMLSConversationId = conversationID
        }
      }
      .task(id: appState.userDID) { draft = nil; await restore() }
      .onReceive(NotificationCenter.default.publisher(for: .directComposeDraftReady)) { notification in
        guard notification.object as? String == appState.userDID else { return }
        Task { await restore() }
      }
  }

  @MainActor private func restore() async {
    let account = appState.userDID
    guard let database = appState.mlsDatabase else { return }
    let pending = try? await MLSDirectComposeDraftStore.pendingPresentation(accountDID: account, database: database)
    guard account == appState.userDID else { return }
    guard draft == nil, let pending else { return }
    presentedAccount = account
    presentedDatabase = database
    draft = pending
  }

  private func clear() {
    guard let account = presentedAccount, let database = presentedDatabase else { return }
    presentedAccount = nil
    presentedDatabase = nil
    Task { try? await MLSDirectComposeDraftStore.clearPresentation(accountDID: account, database: database) }
  }
}
