import CatbirdMLSCore
import SwiftUI

struct MLSOptionalGroupIntroductionSection: View {
  @Binding var text: String
  var body: some View {
    Section {
      TextField("Optional invitation note", text: $text, axis: .vertical)
        .lineLimit(3...6)
      if text.utf8.count > 16_384 { Text("Use at most 16 KiB of text.").foregroundStyle(.red) }
    } header: { Text("Separate encrypted introductions") } footer: {
      Text("The group is created first. You can then review and send this note separately to each selected invitee. Accepting a note never accepts the group invitation.")
    }
  }
}

struct MLSGroupInvitationNotesView: View {
  @Environment(AppState.self) private var appState
  @State private var batch: MLSGroupInvitationNotes
  @State private var draft: MLSDirectComposeDraft?
  @State private var statuses: [String: String] = [:]
  @State private var busy = false
  @State private var saved = false
  @State private var error: String?
  let onDone: () -> Void

  init(batch: MLSGroupInvitationNotes, onDone: @escaping () -> Void) {
    _batch = State(initialValue: batch)
    self.onDone = onDone
  }

  var body: some View {
    List {
      Section {
        Label("Group created", systemImage: "checkmark.circle")
        Text("Group invitations are separate from these optional notes. No note has been sent by creating the group.")
        if saved { Text(verbatim: batch.text) }
        else { TextField("Optional introduction", text: $batch.text, axis: .vertical).lineLimit(3...6) }
        if let error { Text(error).foregroundStyle(.red) }
        if !saved { Button("Save notes for later") { Task { await save() } }.disabled(busy) }
      }
      Section("Review each note") {
        ForEach(batch.recipients, id: \.self) { recipient in
          VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: recipient).font(.caption).textSelection(.enabled)
            Text(statuses[recipient] ?? "Not sent — review required").foregroundStyle(.secondary)
            Button("Review note") { Task { await open(recipient) } }.disabled(busy || !saved)
          }
        }
      }
      Section {
        Button("Open group") {
          appState.navigationManager.targetMLSConversationId = batch.conversationID
          onDone()
        }
        Button("Done") { onDone() }.disabled(!saved)
        Text("Saved notes remain in Chat Requests. If delivery is uncertain, inspect the direct conversation before taking another action.").font(.caption).foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Invitation Notes")
    .task { await save() }
    .onChange(of: appState.userDID) { _, _ in onDone() }
    .sheet(item: $draft) { draft in
      MLSDirectComposeView(draft: draft) { conversationID in
        appState.navigationManager.targetMLSConversationId = conversationID
      }
    }
  }

  @MainActor private func save() async {
    guard !busy, appState.userDID == batch.accountDID, let database = appState.mlsDatabase else { return }
    busy = true
    defer { busy = false }
    do {
      if let existing = try await MLSGroupInvitationNotesStore.list(accountDID: batch.accountDID, database: database).first(where: { $0.id == batch.id }) {
        guard appState.userDID == batch.accountDID else { return }
        batch = existing
      }
      guard appState.userDID == batch.accountDID else { return }
      try await MLSGroupInvitationNotesStore.save(batch, database: database)
      guard appState.userDID == batch.accountDID else { return }
      saved = true
      error = nil
    } catch {
      guard appState.userDID == batch.accountDID else { return }
      self.error = "The group was created, but its optional notes could not be saved. Retry saving here; do not create the group again."
    }
  }

  @MainActor private func open(_ recipient: String) async {
    guard !busy, saved, appState.userDID == batch.accountDID else { return }
    busy = true
    defer { busy = false }
    do {
      guard let manager = await appState.getMLSConversationManager(), manager.currentUserDID == batch.accountDID else { return }
      if let id = batch.drafts[recipient] {
        guard let (retained, archived) = try await MLSGroupInvitationNotesStore.draftStatus(id: id, accountDID: batch.accountDID, database: manager.database) else {
          throw MLSDirectComposeDraftStore.Failure.immutableSubmittedDraft
        }
        guard appState.userDID == batch.accountDID, appState.mlsConversationManager === manager else { return }
        if archived {
          statuses[recipient] = retained.conversationID == nil ? "Request cancelled — retained without retry" : "Sent — open the direct conversation to inspect"
          if let conversation = retained.conversationID { appState.navigationManager.targetMLSConversationId = conversation }
        } else {
          statuses[recipient] = retained.noteAttempted == true ? "Delivery uncertain — inspect the direct conversation" : "Saved introduction — Send is a separate action"
          draft = retained
        }
        return
      }
      guard let verified = try await manager.getGroupInvitationReference(conversationId: batch.conversationID, recipientDid: recipient),
            verified.conversationId == batch.conversationID, verified.recipientDid == recipient,
            verified.invitedByDid == batch.accountDID,
            appState.userDID == batch.accountDID, appState.mlsConversationManager === manager else {
        statuses[recipient] = "The group exists, but a current invitation reference is unavailable. Retry Review note; this never invites again."
        return
      }
      var prepared = try await MLSDirectComposeDraftStore.invitationDraft(accountDID: batch.accountDID, reference: MLSGroupInvitationReference(verified: verified), database: manager.database)
      if !prepared.submitted && prepared.text.isEmpty {
        prepared.text = batch.text
        try await MLSDirectComposeDraftStore.save(prepared, database: manager.database)
      }
      var updated = batch
      updated.drafts[recipient] = prepared.id
      try await MLSGroupInvitationNotesStore.save(updated, database: manager.database)
      batch = updated
      guard appState.userDID == batch.accountDID, appState.mlsConversationManager === manager else { return }
      statuses[recipient] = "Saved introduction — Send is a separate action"
      draft = prepared
    } catch {
      guard appState.userDID == batch.accountDID else { return }
      statuses[recipient] = "The group invitation is unchanged. Note preparation failed; retry Review note."
    }
  }
}
