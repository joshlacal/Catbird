//
//  MLSCleanSlateModels.swift
//  Catbird
//
//  Spaces-only clean-slate UI models, Space blob locator (I14), request gate,
//  compose draft store, moderation report sheet, and block coordinator.
//

import AVFoundation
import CatbirdMLSCore
import Foundation
import OSLog
import Petrel
import PetrelCatbird
import PhotosUI
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Space-Scoped Blob Locator (I14)

enum MLSSpaceBlobLocatorError: LocalizedError {
  case invalidLocator(String)

  var errorDescription: String? {
    switch self {
    case .invalidLocator(let value):
      return String(localized: "Invalid Space blob locator: \(value)", comment: "Technical error when an encrypted attachment locator cannot be parsed. %@ is the invalid locator.")
    }
  }
}

enum MLSSpaceBlobLocator {
  /// Format a Space-scoped blob reference: `"{spaceURI}|{repoDID}|{cid}"`.
  static func makeLocator(spaceURI: String, repoDID: String, cid: String) -> String {
    "\(spaceURI)|\(repoDID)|\(cid)"
  }

  /// Parse either `"{spaceURI}|{repoDID}|{cid}"` or `"at://{spaceDID}/space/{spaceType}/{skey}/{repoDID}#{cid}"`.
  static func parse(_ rawLocator: String) throws -> (space: SpaceRef, repo: DID, cid: CID) {
    let trimmed = rawLocator.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("|") {
      let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard parts.count == 3 else {
        throw MLSSpaceBlobLocatorError.invalidLocator(rawLocator)
      }
      let space = try SpaceRef(uriString: parts[0])
      let repo = try DID(didString: parts[1])
      let cid = try CID.parse(parts[2])
      return (space, repo, cid)
    }

    if let hashIndex = trimmed.firstIndex(of: "#") {
      let beforeHash = String(trimmed[..<hashIndex])
      let cidPart = String(trimmed[trimmed.index(after: hashIndex)...])
      guard let lastSlash = beforeHash.lastIndex(of: "/") else {
        throw MLSSpaceBlobLocatorError.invalidLocator(rawLocator)
      }
      let spaceURI = String(beforeHash[..<lastSlash])
      let repoPart = String(beforeHash[beforeHash.index(after: lastSlash)...])
      let space = try SpaceRef(uriString: spaceURI)
      let repo = try DID(didString: repoPart)
      let cid = try CID.parse(cidPart)
      return (space, repo, cid)
    }

    throw MLSSpaceBlobLocatorError.invalidLocator(rawLocator)
  }

  /// Fetch an encrypted blob from its conversation Space via `com.atproto.space.getBlob` (`I14`).
  static func fetchEncryptedBlob(
    blobId: String,
    using client: ATProtoClient
  ) async throws -> (responseCode: Int, data: Data?) {
    let parsed = try parse(blobId)
    let (responseCode, output) = try await client.com.atproto.space.getBlob(
      input: ComAtprotoSpaceGetBlob.Parameters(
        space: parsed.space,
        repo: parsed.repo,
        cid: CIDString(parsed.cid)
      )
    )
    return (responseCode, output?.data)
  }
}

// MARK: - Request Presentation & Acceptance Fence

enum MLSChatRequestPresentation {
  static func groupTitle(_ raw: String?) -> String {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty
    else {
      return String(localized: "Group chat invitation", comment: "Fallback title for an unnamed encrypted group chat invitation")
    }
    return trimmed
  }
}

enum MLSChatRequestAcceptance {
  @MainActor
  static func perform(
    conversationID: String,
    isCurrent: @MainActor () -> Bool,
    accept: @MainActor (String) async throws -> Void,
    didAccept: @MainActor (String) -> Void
  ) async throws {
    guard isCurrent() else { throw CancellationError() }
    try await accept(conversationID)
    guard isCurrent() else { throw CancellationError() }
    didAccept(conversationID)
  }
}

// MARK: - Direct Compose Drafts & Group Invitation Notes

struct MLSDirectComposeDraft: Identifiable, Hashable, Codable, Sendable {
  let id: UUID
  let accountDID: String
  let recipientDID: String
  var recipientHandle: String?
  var recipientDisplayName: String?
  var text: String
  var submitted: Bool
  var noteAttempted: Bool?
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    accountDID: String,
    recipientDID: String,
    recipientHandle: String? = nil,
    recipientDisplayName: String? = nil,
    text: String = "",
    submitted: Bool = false,
    noteAttempted: Bool? = nil,
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.accountDID = accountDID
    self.recipientDID = recipientDID
    self.recipientHandle = recipientHandle
    self.recipientDisplayName = recipientDisplayName
    self.text = text
    self.submitted = submitted
    self.noteAttempted = noteAttempted
    self.updatedAt = updatedAt
  }
}

enum MLSDirectComposeDraftStore {
  static let didRequestPresentation = Notification.Name("CatbirdMLSDirectComposePresentationRequested")

  enum Failure: LocalizedError {
    case invalidText
    case accountChanged
    case immutableSubmittedDraft

    var errorDescription: String? {
      switch self {
      case .invalidText:
        return String(localized: "Write a non-empty message up to 1,000 characters.", comment: "Validation error for an opening encrypted direct message")
      case .accountChanged:
        return String(localized: "The active account changed.", comment: "Error when the signed-in account changes during compose")
      case .immutableSubmittedDraft:
        return String(localized: "This request has already been submitted.", comment: "Error when attempting to re-submit an already sent encrypted chat request")
      }
    }
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var draftsByKey: [String: MLSDirectComposeDraft] = [:]

  private static func key(accountDID: String, recipientDID: String) -> String {
    "\(accountDID)|\(recipientDID)"
  }

  static func validateText(_ text: String) throws {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 1_000 else {
      throw Failure.invalidText
    }
  }

  static func open(accountDID: String, recipientDID: String) -> MLSDirectComposeDraft {
    lock.lock()
    defer { lock.unlock() }
    let storageKey = key(accountDID: accountDID, recipientDID: recipientDID)
    if let existing = draftsByKey[storageKey] {
      return existing
    }
    let created = MLSDirectComposeDraft(accountDID: accountDID, recipientDID: recipientDID)
    draftsByKey[storageKey] = created
    return created
  }

  static func save(_ draft: MLSDirectComposeDraft) {
    lock.lock()
    defer { lock.unlock() }
    var updated = draft
    updated.updatedAt = Date()
    draftsByKey[key(accountDID: draft.accountDID, recipientDID: draft.recipientDID)] = updated
  }

  static func archive(_ draft: MLSDirectComposeDraft) {
    lock.lock()
    defer { lock.unlock() }
    draftsByKey.removeValue(forKey: key(accountDID: draft.accountDID, recipientDID: draft.recipientDID))
  }

  static func reopenAfterTerminal(_ draft: MLSDirectComposeDraft) -> MLSDirectComposeDraft {
    lock.lock()
    defer { lock.unlock() }
    let reopened = MLSDirectComposeDraft(
      accountDID: draft.accountDID,
      recipientDID: draft.recipientDID,
      recipientHandle: draft.recipientHandle,
      recipientDisplayName: draft.recipientDisplayName,
      text: draft.text
    )
    draftsByKey[key(accountDID: draft.accountDID, recipientDID: draft.recipientDID)] = reopened
    return reopened
  }

  static func savedInvitationNotes(accountDID: String) -> [MLSDirectComposeDraft] {
    lock.lock()
    defer { lock.unlock() }
    return draftsByKey.values
      .filter { $0.accountDID == accountDID && !$0.text.isEmpty }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  static func requestPresentation(_ draft: MLSDirectComposeDraft) {
    save(draft)
    NotificationCenter.default.post(name: didRequestPresentation, object: draft)
  }
}

struct MLSGroupInvitationNotes: Identifiable, Hashable, Codable, Sendable {
  let id: String
  let accountDID: String
  let conversationID: String
  let recipients: [String]
  let text: String

  init(
    id: String = UUID().uuidString.lowercased(),
    accountDID: String,
    conversationID: String,
    recipients: [String],
    text: String
  ) {
    self.id = id
    self.accountDID = accountDID
    self.conversationID = conversationID
    self.recipients = recipients
    self.text = text
  }
}

enum MLSGroupInvitationNotesStore {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var notesByID: [String: MLSGroupInvitationNotes] = [:]

  static func save(_ batch: MLSGroupInvitationNotes) {
    lock.lock()
    defer { lock.unlock() }
    notesByID[batch.id] = batch
  }

  static func remove(id: String) {
    lock.lock()
    defer { lock.unlock() }
    notesByID.removeValue(forKey: id)
  }

  static func list(accountDID: String) -> [MLSGroupInvitationNotes] {
    lock.lock()
    defer { lock.unlock() }
    return notesByID.values.filter { $0.accountDID == accountDID }
  }
}

// MARK: - Direct Compose & Group Invitation Views

enum MLSDirectComposeSendGate {
  static func canSend(text: String, capability: MLSChatCapability?, isSubmitting: Bool) -> Bool {
    !isSubmitting
      && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && capability?.isCapable == true
  }
}

struct MLSDirectComposeView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  let draft: MLSDirectComposeDraft
  let onCreated: (String) -> Void

  @State private var messageText: String
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  /// The recipient's encrypted chat answer. This screen is also reached from Siri, shortcuts
  /// and links, so it says plainly when the person cannot be messaged this way yet.
  @State private var recipientCapability: MLSChatCapability?
  @State private var capabilityCheckID = UUID()

  init(draft: MLSDirectComposeDraft, onCreated: @escaping (String) -> Void) {
    self.draft = draft
    self.onCreated = onCreated
    _messageText = State(initialValue: draft.text)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Recipient") {
          Text(draft.recipientDisplayName ?? draft.recipientHandle.map { "@\($0)" } ?? draft.recipientDID)
            .font(.headline)
        }
        Section("Opening Encrypted Message") {
          TextEditor(text: $messageText)
            .frame(minHeight: 110)
        }
        if let capability = recipientCapability, let notice = ChatFailureMessage.text(for: capability) {
          Section {
            Text(notice)
              .font(.footnote)
              .foregroundStyle(.secondary)
            if case .unknown = capability {
              Button("Try again") {
                Task { await checkRecipient(forceRefresh: true) }
              }
              .disabled(isSubmitting)
            } else {
              Text("You can send them a Bluesky DM from New Message.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
        }
        if let errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
              .font(.footnote)
          }
        }
      }
      .navigationTitle("New Encrypted Chat")
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Send") {
            Task { await sendInitialMessage() }
          }
          .disabled(!MLSDirectComposeSendGate.canSend(
            text: messageText, capability: recipientCapability, isSubmitting: isSubmitting))
        }
      }
      .task { await checkRecipient(forceRefresh: false) }
    }
  }

  @MainActor
  private func checkRecipient(forceRefresh: Bool) async {
    let checkID = UUID()
    capabilityCheckID = checkID
    recipientCapability = nil
    let result = await MLSChatCapabilityResolver.shared.capability(
      for: draft.recipientDID, forceRefresh: forceRefresh)
    guard !Task.isCancelled, capabilityCheckID == checkID, draft.accountDID == appState.userDID else { return }
    recipientCapability = result
  }

  @MainActor
  private func sendInitialMessage() async {
    guard MLSDirectComposeSendGate.canSend(
      text: messageText, capability: recipientCapability, isSubmitting: isSubmitting),
      draft.accountDID == appState.userDID else { return }
    let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    isSubmitting = true
    defer { isSubmitting = false }
    do {
      try MLSDirectComposeDraftStore.validateText(trimmed)
      await checkRecipient(forceRefresh: true)
      guard !Task.isCancelled, draft.accountDID == appState.userDID else { return }
      guard recipientCapability?.isCapable == true else { return }
      guard let coordinator = await appState.getOrOpenMLSCoordinator() else {
        errorMessage = String(localized: "Encrypted chat isn’t ready on this device yet. Try again in a moment.", comment: "Error when the MLS coordinator is not yet ready")
        return
      }
      guard !Task.isCancelled, draft.accountDID == appState.userDID,
            recipientCapability?.isCapable == true else { return }
      let outcome = try await MLSDirectChatStart.start(
        coordinator: coordinator,
        sequencerDID: appState.defaultMLSSequencerDID,
        recipientDID: draft.recipientDID,
        text: trimmed
      )
      if let notice = outcome.delivery.notice {
        // The text was not delivered; keep it in the sheet and say why.
        errorMessage = notice
        return
      }
      MLSDirectComposeDraftStore.archive(draft)
      onCreated(outcome.conversationID)
      dismiss()
    } catch {
      errorMessage = ChatFailureMessage.text(for: error, context: .startEncryptedChat)
    }
  }
}

struct MLSDirectDraftPresentation: ViewModifier {
  @Environment(AppState.self) private var appState
  @State private var presentedDraft: MLSDirectComposeDraft?

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: MLSDirectComposeDraftStore.didRequestPresentation)) { note in
        guard let draft = note.object as? MLSDirectComposeDraft,
              draft.accountDID == appState.userDID else {
          return
        }
        presentedDraft = draft
      }
      .sheet(item: $presentedDraft) { draft in
        MLSDirectComposeView(draft: draft) { conversationID in
          presentedDraft = nil
          appState.navigateToMLSConversation(conversationID)
        }
        .environment(appState)
      }
  }
}

struct MLSGroupInvitationNotesView: View {
  let batch: MLSGroupInvitationNotes
  let onDone: () -> Void

  var body: some View {
    Form {
      Section("Invitation Note") {
        Text(verbatim: batch.text)
      }
      Section("Recipients (\(batch.recipients.count))") {
        ForEach(batch.recipients, id: \.self) { recipient in
          Text(verbatim: recipient)
            .font(.footnote.monospaced())
        }
      }
      Section {
        Button("Done") {
          MLSGroupInvitationNotesStore.remove(id: batch.id)
          onDone()
        }
      }
    }
    .navigationTitle("Invitation Notes")
  }
}

// MARK: - Verified Request Conversation Gate

struct MLSRequestConversationGate<Content: View>: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  let conversationID: String
  var onAccepted: ((String) -> Void)?
  @ViewBuilder let content: () -> Content

  @State private var pendingRequest: MLSRequestRow?
  @State private var hasChecked = false
  @State private var isMutating = false
  @State private var errorMessage: String?

  init(
    conversationID: String,
    onAccepted: ((String) -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.conversationID = conversationID
    self.onAccepted = onAccepted
    self.content = content
  }

  var body: some View {
    Group {
      if !hasChecked {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let request = pendingRequest {
        requestGateBody(request)
      } else {
        content()
      }
    }
    .task(id: "\(appState.userDID):\(conversationID)") {
      await loadPendingRequest()
    }
  }

  private func requestGateBody(_ request: MLSRequestRow) -> some View {
    VStack(spacing: 20) {
      Spacer()
      Image(systemName: "lock.shield")
        .font(.system(size: 44))
        .foregroundStyle(.secondary)
      Text("Encrypted Chat Request")
        .font(.title3.bold())
      if let previewText = request.previewText {
        Text(verbatim: previewText)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      } else {
        Text("Wants to start an end-to-end encrypted chat.")
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }
      if let errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
      }
      Spacer()
      HStack(spacing: 12) {
        Button(role: .destructive) {
          Task { await decline(request) }
        } label: {
          Text("Decline")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isMutating)

        Button {
          Task { await accept(request) }
        } label: {
          Text("Accept")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isMutating)
      }
      .padding()
    }
  }

  @MainActor
  private func loadPendingRequest() async {
    defer { hasChecked = true }
    guard let coordinator = appState.mlsCoordinator else {
      pendingRequest = nil
      return
    }
    let requests = (try? await coordinator.listRequests(consentFilter: "incomingPending")) ?? []
    pendingRequest = requests.first {
      $0.conversationId == conversationID || $0.requestId == conversationID
    }
  }

  @MainActor
  private func accept(_ request: MLSRequestRow) async {
    guard let coordinator = appState.mlsCoordinator else { return }
    isMutating = true
    defer { isMutating = false }
    do {
      try await coordinator.acceptDirectRequest(requestId: request.requestId)
      pendingRequest = nil
      onAccepted?(conversationID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func decline(_ request: MLSRequestRow) async {
    guard let coordinator = appState.mlsCoordinator else { return }
    isMutating = true
    defer { isMutating = false }
    do {
      try await coordinator.declineDirectRequest(requestId: request.requestId)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Request Delivery Settings, Block Sheet, & Report Spam Sheet

struct MLSRequestDeliverySettingsSection: View {
  @AppStorage("mls.whoCanMessageMe") private var policyRaw: String = MLSWhoCanMessageMe.everyone.rawValue

  var body: some View {
    Section {
      Picker("Encrypted Chat Requests", selection: $policyRaw) {
        Text("Everyone").tag(MLSWhoCanMessageMe.everyone.rawValue)
        Text("People I Follow").tag(MLSWhoCanMessageMe.following.rawValue)
        Text("Mutuals Only").tag(MLSWhoCanMessageMe.mutuals.rawValue)
        Text("No One").tag(MLSWhoCanMessageMe.nobody.rawValue)
      }
    } header: {
      Text("Encrypted Requests")
    } footer: {
      Text("Controls who can send you end-to-end encrypted direct requests.")
    }
  }
}

struct BlockChatSenderSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  let senderDid: String
  let senderHandle: String?
  let senderDisplayName: String?
  var requestId: String = ""
  var conversationId: String? = nil
  let onBlocked: () -> Void

  @State private var isSubmitting = false
  @State private var leaveConversationToo = true
  @State private var errorMessage: String?

  private var displayTarget: String {
    senderDisplayName ?? senderHandle.map { "@\($0)" } ?? String(localized: "this account", comment: "Fallback noun phrase when blocking an account with no display name or handle")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          if !requestId.isEmpty {
            Text("Block \(displayTarget) and close this encrypted request?")
          } else {
            Text("Block \(displayTarget) on Bluesky? Blocked accounts cannot start new encrypted chats with you.")
            if conversationId != nil {
              Toggle("Also leave this encrypted conversation", isOn: $leaveConversationToo)
            }
          }
        }
        if let errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
              .font(.footnote)
          }
        }
      }
      .navigationTitle("Block Account")
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Block", role: .destructive) {
            Task { await performBlock() }
          }
          .disabled(isSubmitting)
        }
      }
    }
  }

  @MainActor
  private func performBlock() async {
    isSubmitting = true
    defer { isSubmitting = false }
    do {
      if let coordinator = appState.mlsCoordinator {
        let blockCoordinator = MLSBlockCoordinator(
          coordinator: coordinator,
          graphManager: appState.graphManager
        )
        try await blockCoordinator.block(did: senderDid)
      } else if !(await appState.graphManager.isBlocking(did: senderDid)) {
        _ = try await appState.graphManager.block(did: senderDid)
      }
      if !requestId.isEmpty {
        try? await appState.mlsCoordinator?.declineDirectRequest(requestId: requestId)
      }
      if let conversationId, leaveConversationToo, let coordinator = appState.mlsCoordinator {
        _ = try await coordinator.leaveConversation(conversationId: conversationId)
        await appState.loadMLSConversations()
      }
      onBlocked()
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct MLSReportSpamSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  let conversationId: String
  let reportedDid: String
  let reportedDisplayName: String
  var apiClient: MLSAPIClient? = nil
  var client: ATProtoClient? = nil

  @State private var reasonText = ""
  @State private var isSubmitting = false
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("Account") {
          Text(reportedDisplayName)
        }
        Section("Details (Optional)") {
          TextEditor(text: $reasonText)
            .frame(minHeight: 90)
        }
        if let errorMessage {
          Section {
            Text(errorMessage)
              .foregroundStyle(.red)
              .font(.footnote)
          }
        }
      }
      .navigationTitle("Report Account")
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Submit") {
            Task { await submitReport() }
          }
          .disabled(isSubmitting)
        }
      }
    }
  }

  @MainActor
  private func submitReport() async {
    guard let activeClient = apiClient?.client ?? client ?? appState.atProtoClient else {
      errorMessage = String(localized: "Reporting is unavailable while offline.", comment: "Error when submitting a moderation report without a network client")
      return
    }
    isSubmitting = true
    defer { isSubmitting = false }
    do {
      let subjectRepo = ComAtprotoAdminDefs.RepoRef(did: try DID(didString: reportedDid))
      let input = ComAtprotoModerationCreateReport.Input(
        reasonType: ComAtprotoModerationDefs.ReasonType(rawValue: "com.atproto.moderation.defs#reasonSpam"),
        reason: reasonText.isEmpty ? "Encrypted chat report (\(conversationId.prefix(8)))" : reasonText,
        subject: .comAtprotoAdminDefsRepoRef(subjectRepo)
      )
      _ = try await activeClient.com.atproto.moderation.createReport(input: input)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Block Coordinator

@MainActor
final class MLSBlockCoordinator {
  private let coordinator: MLSClientCoordinator
  private let graphManager: GraphManager
  private let logger = Logger(subsystem: "blue.catbird", category: "MLSBlockCoordinator")

  init(coordinator: MLSClientCoordinator, graphManager: GraphManager) {
    self.coordinator = coordinator
    self.graphManager = graphManager
  }

  func block(did: String) async throws {
    if !(await graphManager.isBlocking(did: did)) {
      _ = try await graphManager.block(did: did)
    }
    if let requests = try? await coordinator.listRequests(consentFilter: "incomingPending") {
      for request in requests where request.senderDid == did {
        try? await coordinator.declineDirectRequest(requestId: request.requestId)
      }
    }
    logger.info("Published ATProto block and reconciled pending MLS requests")
  }

  func unblock(did: String) async throws {
    if await graphManager.isBlocking(did: did) {
      _ = try await graphManager.unblock(did: did)
    }
    logger.info("Removed ATProto block for \(did, privacy: .private)")
  }

  func affectedConversations(for did: String) async -> [MLSConversationModel] {
    guard let rows = try? await coordinator.listConversations(limit: 100) else { return [] }
    let selfDID = coordinator.accountDid
    var matched: [MLSConversationModel] = []
    for row in rows {
      if let messages = try? await coordinator.listMessages(conversationId: row.conversationId, limit: 50),
         messages.contains(where: { $0.senderDid == did })
      {
        matched.append(MLSConversationModel(row: row, currentUserDID: selfDID))
      }
    }
    return matched
  }
}

// MARK: - UniFFI Row Presentation Helpers

extension MLSConversationRow {
  var groupIdHex: String {
    groupId.hexEncodedString()
  }
}

extension MLSMessageRow {
  var plaintext: String {
    if let payload = try? MLSMessagePayload.decodeFromJSON(Data(plaintextJson.utf8)),
       let text = payload.text
    {
      return text
    }
    return plaintextJson
  }
}

extension MLSRequestRow {
  var previewText: String? {
    if let payload = try? MLSMessagePayload.decodeFromJSON(Data(payloadJson.utf8)),
       let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty
    {
      return text
    }
    let trimmed = payloadJson.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

// MARK: - Encrypted Image Attachment Preparation

@Observable
final class MLSImageSender {
  var isUploading = false
  var uploadError: String?

  private let client: ATProtoClient
  @ObservationIgnored private weak var coordinator: MLSClientCoordinator?
  private let logger = Logger(subsystem: "blue.catbird", category: "MLSImageSender")
  private static let maxBlobBytes = 10 * 1024 * 1024

  init(client: ATProtoClient, coordinator: MLSClientCoordinator? = nil) {
    self.client = client
    self.coordinator = coordinator
  }

  @MainActor
  func processImage(
    from item: PhotosPickerItem,
    convoId: String,
    coordinator overrideCoordinator: MLSClientCoordinator? = nil
  ) async -> MLSImageEmbed? {
    _ = client
    isUploading = true
    uploadError = nil
    defer { isUploading = false }

    do {
      guard let imageData = try await item.loadTransferable(type: Data.self) else {
        uploadError = String(localized: "Could not load image", comment: "Error when loading a selected image attachment fails")
        return nil
      }
      guard let platformImage = PlatformImage(data: imageData) else {
        uploadError = String(localized: "Invalid image format", comment: "Error when selected image data cannot be decoded")
        return nil
      }

      let originalWidth = Int(platformImage.imageSize.width * platformImage.imageScale)
      let originalHeight = Int(platformImage.imageSize.height * platformImage.imageScale)
      let detectedType = Self.detectMimeType(from: imageData)

      let finalData: Data
      let contentType: String
      var finalWidth = originalWidth
      var finalHeight = originalHeight

      if imageData.count <= Self.maxBlobBytes {
        finalData = imageData
        contentType = detectedType
      } else if detectedType == "image/png" {
        guard let result = Self.fitPNG(platformImage, maxBytes: Self.maxBlobBytes) else {
          uploadError = String(localized: "Image too large (max 10 MB)", comment: "Error when an image attachment exceeds the 10 MB limit")
          return nil
        }
        finalData = result.data
        finalWidth = result.width
        finalHeight = result.height
        contentType = "image/png"
      } else {
        guard let result = Self.fitJPEG(platformImage, maxBytes: Self.maxBlobBytes) else {
          uploadError = String(localized: "Image too large (max 10 MB)")
          return nil
        }
        finalData = result.data
        finalWidth = result.width
        finalHeight = result.height
        contentType = "image/jpeg"
      }

      let resolvedCoordinator: MLSClientCoordinator?
      if let overrideCoordinator {
        resolvedCoordinator = overrideCoordinator
      } else if let coordinator {
        resolvedCoordinator = coordinator
      } else {
        resolvedCoordinator = AppStateManager.shared.lifecycle.appState?.mlsCoordinator
      }
      guard let activeCoordinator = resolvedCoordinator else {
        uploadError = String(localized: "Encrypted chat coordinator is unavailable", comment: "Error when sending an encrypted attachment without an active MLS coordinator")
        return nil
      }

      let uploaded = try await activeCoordinator.uploadConversationAttachment(
        conversationId: convoId,
        plaintext: finalData,
        mimeType: contentType
      )
      logger.info("Uploaded Space-encrypted image attachment \(uploaded.locator, privacy: .public)")

      return MLSImageEmbed(
        blobId: uploaded.locator,
        key: uploaded.symmetricKey,
        iv: uploaded.iv,
        sha256: uploaded.ciphertextSha256.hexEncodedString(),
        contentType: uploaded.mimeType,
        size: Int(clamping: uploaded.ciphertextSize),
        width: finalWidth,
        height: finalHeight,
        altText: nil,
        blurhash: nil
      )
    } catch {
      logger.error("Image processing error: \(error.localizedDescription)")
      uploadError = String(localized: "Failed to send image: \(error.localizedDescription)", comment: "Error when uploading an encrypted image attachment fails. %@ is the error description.")
      return nil
    }
  }

  private static func detectMimeType(from data: Data) -> String {
    guard data.count >= 12 else { return "image/jpeg" }
    let header = [UInt8](data.prefix(12))
    if header[0] == 0x89, header[1] == 0x50, header[2] == 0x4E, header[3] == 0x47 { return "image/png" }
    if header[0] == 0xFF, header[1] == 0xD8 { return "image/jpeg" }
    if header[0] == 0x47, header[1] == 0x49, header[2] == 0x46 { return "image/gif" }
    if header[4] == 0x66, header[5] == 0x74, header[6] == 0x79, header[7] == 0x70 { return "image/heic" }
    return "image/jpeg"
  }

  private struct FitResult {
    let data: Data
    let width: Int
    let height: Int
  }

  private static func fitPNG(_ image: PlatformImage, maxBytes: Int) -> FitResult? {
    let pw = image.imageSize.width * image.imageScale
    let ph = image.imageSize.height * image.imageScale
    var scale: CGFloat = 0.75
    for _ in 0..<8 {
      let w = pw * scale
      let h = ph * scale
      if let resized = image.resized(to: CGSize(width: w, height: h)) {
        #if os(iOS)
        if let data = resized.pngData(), data.count <= maxBytes {
          return FitResult(data: data, width: Int(w), height: Int(h))
        }
        #else
        if let data = resized.pngImageData(), data.count <= maxBytes {
          return FitResult(data: data, width: Int(w), height: Int(h))
        }
        #endif
      }
      scale *= 0.75
    }
    return nil
  }

  private static func fitJPEG(_ image: PlatformImage, maxBytes: Int) -> FitResult? {
    let pw = image.imageSize.width * image.imageScale
    let ph = image.imageSize.height * image.imageScale

    for q: CGFloat in [0.8, 0.6, 0.4] {
      #if os(iOS)
      if let data = image.jpegData(compressionQuality: q), data.count <= maxBytes {
        return FitResult(data: data, width: Int(pw), height: Int(ph))
      }
      #else
      if let data = image.jpegImageData(compressionQuality: q), data.count <= maxBytes {
        return FitResult(data: data, width: Int(pw), height: Int(ph))
      }
      #endif
    }

    var scale: CGFloat = 0.75
    for _ in 0..<6 {
      let w = pw * scale
      let h = ph * scale
      if let resized = image.resized(to: CGSize(width: w, height: h)) {
        for q: CGFloat in [0.8, 0.5] {
          #if os(iOS)
          if let data = resized.jpegData(compressionQuality: q), data.count <= maxBytes {
            return FitResult(data: data, width: Int(w), height: Int(h))
          }
          #else
          if let data = resized.jpegImageData(compressionQuality: q), data.count <= maxBytes {
            return FitResult(data: data, width: Int(w), height: Int(h))
          }
          #endif
        }
      }
      scale *= 0.75
    }
    return nil
  }
}

// MARK: - Encrypted Voice Message Recording & Opus Preparation (FC-09)

@MainActor
@Observable
final class MLSVoiceSender {
  #if os(iOS)
  private(set) var voiceMode: ComposerMode = .compose
  #endif
  private(set) var voicePreviewURL: URL?
  private(set) var recordingDuration: TimeInterval = 0
  private(set) var isUploading = false
  var voiceError: String?

  @ObservationIgnored private let audioSession: any AudioRecordingSession
  @ObservationIgnored private let requestPermission: @MainActor () async -> Bool
  @ObservationIgnored private let makeRecorder: @MainActor (URL, [String: Any]) throws -> any AudioRecordingDevice
  @ObservationIgnored private var recorder: (any AudioRecordingDevice)?
  @ObservationIgnored private var recordingSessionOwner: UUID?
  @ObservationIgnored private var pendingStartID: UUID?
  @ObservationIgnored private var startRecordingTask: Task<Void, Never>?
  @ObservationIgnored private var durationTimer: Timer?
  @ObservationIgnored private var recordingStartDate: Date?
  @ObservationIgnored private var activeWavURL: URL?
  @ObservationIgnored private var activePcmURL: URL?
  @ObservationIgnored private var preparedVoice: VoicePrepareResult?
  private let logger = Logger(subsystem: "blue.catbird", category: "MLSVoiceSender")

  private static let sampleRate: Double = 48_000

  init(
    audioSession: any AudioRecordingSession = AudioSessionManager.shared,
    requestPermission: @escaping @MainActor () async -> Bool = { await MLSVoiceSender.requestMicrophonePermission() },
    makeRecorder: @escaping @MainActor (URL, [String: Any]) throws -> any AudioRecordingDevice = {
      try AVAudioRecorder(url: $0, settings: $1)
    }
  ) {
    self.audioSession = audioSession
    self.requestPermission = requestPermission
    self.makeRecorder = makeRecorder
  }

  isolated deinit {
    startRecordingTask?.cancel()
    startRecordingTask = nil
    durationTimer?.invalidate()
    durationTimer = nil
    recorder?.stop()
    recorder = nil
    if let owner = recordingSessionOwner {
      recordingSessionOwner = nil
      audioSession.resetAfterRecording(owner: owner)
    }
  }

  func startRecording() {
    cancelOrDiscard()
    voiceError = nil
    let startID = UUID()
    pendingStartID = startID
    let session = audioSession
    startRecordingTask = Task { @MainActor [weak self] in
      let permitted: Bool
      do {
        guard let permissionCheck = self?.requestPermission else { return }
        permitted = await permissionCheck()
      }

      let owner = UUID()
      let shouldConfigure: Bool = {
        guard let self, !Task.isCancelled, self.pendingStartID == startID else { return false }
        guard permitted else {
          self.pendingStartID = nil
          self.startRecordingTask = nil
          self.voiceError = String(localized: "Microphone access is required to record voice messages.", comment: "Error when microphone permission is denied for voice messages")
          return false
        }
        self.recordingSessionOwner = owner
        return true
      }()
      guard shouldConfigure else { return }

      do {
        try await session.configureForRecording(owner: owner)
      } catch {
        session.resetAfterRecording(owner: owner)
        if let self {
          if self.recordingSessionOwner == owner {
            self.recordingSessionOwner = nil
          }
          if self.pendingStartID == startID {
            self.pendingStartID = nil
            self.startRecordingTask = nil
          }
          if !Task.isCancelled {
            self.logger.error("Failed to start voice recorder: \(error.localizedDescription)")
            self.voiceError = error.localizedDescription
          }
        }
        return
      }

      guard let self,
            !Task.isCancelled,
            self.pendingStartID == startID,
            self.recordingSessionOwner == owner else {
        session.resetAfterRecording(owner: owner)
        return
      }

      do {
        let wavURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("catbird-mls-voice-\(UUID().uuidString.lowercased()).wav")
        let settings: [String: Any] = [
          AVFormatIDKey: Int(kAudioFormatLinearPCM),
          AVSampleRateKey: Self.sampleRate,
          AVNumberOfChannelsKey: 1,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ]
        let newRecorder = try self.makeRecorder(wavURL, settings)
        guard newRecorder.prepareToRecord(), newRecorder.record() else {
          newRecorder.stop()
          self.archiveTempFile(wavURL)
          self.releaseRecordingSession(owner: owner)
          if self.pendingStartID == startID {
            self.pendingStartID = nil
            self.startRecordingTask = nil
          }
          self.voiceError = String(localized: "Couldn't start voice recording.", comment: "Error when audio recorder fails to start")
          return
        }
        self.recorder = newRecorder
        self.activeWavURL = wavURL
        self.recordingStartDate = Date()
        self.recordingDuration = 0
        self.pendingStartID = nil
        self.startRecordingTask = nil
        #if os(iOS)
        self.voiceMode = .recording(locked: false)
        #endif
        self.startDurationTimer()
      } catch {
        self.releaseRecordingSession(owner: owner)
        if self.pendingStartID == startID {
          self.pendingStartID = nil
          self.startRecordingTask = nil
        }
        guard !Task.isCancelled else { return }
        self.logger.error("Failed to start voice recorder: \(error.localizedDescription)")
        self.voiceError = error.localizedDescription
      }
    }
  }

  func lockRecording() {
    #if os(iOS)
    if case .recording = voiceMode {
      voiceMode = .recording(locked: true)
    }
    #endif
  }

  func stopRecordingToPreview() async {
    startRecordingTask?.cancel()
    startRecordingTask = nil
    pendingStartID = nil
    stopDurationTimer()
    let elapsed = recordingStartDate.map { Date().timeIntervalSince($0) } ?? recordingDuration
    recorder?.stop()
    recorder = nil
    releaseRecordingSession()

    guard let wavURL = activeWavURL else {
      cancelOrDiscard()
      return
    }

    do {
      let pcmURL = try Self.writeRawS16LEPcmFile(fromWavURL: wavURL)
      activePcmURL = pcmURL
      let prepared = try await MLSClientCoordinator.prepareVoiceMessage(
        pcmPath: pcmURL.path,
        sampleRate: UInt32(Self.sampleRate)
      )
      preparedVoice = prepared
      voicePreviewURL = wavURL
      let durationSeconds = max(elapsed, Double(prepared.durationMs) / 1_000.0)
      recordingDuration = durationSeconds
      #if os(iOS)
      voiceMode = .preview(duration: durationSeconds, waveform: prepared.waveform)
      #endif
    } catch {
      logger.error("Failed to encode Opus voice preview: \(error.localizedDescription)")
      voiceError = String(localized: "Couldn't prepare voice message: \(error.localizedDescription)", comment: "Error when Opus encoding of a recorded voice message fails. %@ is the error description.")
      cancelOrDiscard()
    }
  }

  func cancelOrDiscard() {
    startRecordingTask?.cancel()
    startRecordingTask = nil
    pendingStartID = nil
    stopDurationTimer()
    recorder?.stop()
    recorder = nil
    recordingStartDate = nil
    recordingDuration = 0
    preparedVoice = nil
    voicePreviewURL = nil
    #if os(iOS)
    voiceMode = .compose
    #endif
    releaseRecordingSession()
    archiveTempFile(activeWavURL)
    archiveTempFile(activePcmURL)
    activeWavURL = nil
    activePcmURL = nil
  }

  private func releaseRecordingSession(owner specificOwner: UUID? = nil) {
    if let specificOwner {
      if recordingSessionOwner == specificOwner {
        recordingSessionOwner = nil
      }
      audioSession.resetAfterRecording(owner: specificOwner)
    } else if let activeOwner = recordingSessionOwner {
      recordingSessionOwner = nil
      audioSession.resetAfterRecording(owner: activeOwner)
    }
  }

  func sendPreview(
    convoId: String,
    coordinator: MLSClientCoordinator?
  ) async -> MLSAudioEmbed? {
    let resolvedCoordinator = coordinator ?? AppStateManager.shared.lifecycle.appState?.mlsCoordinator
    guard let activeCoordinator = resolvedCoordinator else {
      voiceError = String(localized: "Encrypted chat coordinator is unavailable.", comment: "Error when sending a voice message without an active MLS coordinator")
      return nil
    }
    guard let prepared = preparedVoice else {
      voiceError = String(localized: "No recorded voice message to send.", comment: "Error when attempting to send a voice message with no prepared recording")
      return nil
    }

    isUploading = true
    voiceError = nil
    defer { isUploading = false }

    do {
      let uploaded = try await activeCoordinator.uploadConversationAttachment(
        conversationId: convoId,
        plaintext: prepared.opusData,
        mimeType: "audio/ogg; codecs=opus"
      )
      let embed = MLSAudioEmbed(
        blobId: uploaded.locator,
        key: uploaded.symmetricKey,
        iv: uploaded.iv,
        sha256: uploaded.ciphertextSha256.hexEncodedString(),
        contentType: uploaded.mimeType,
        size: uploaded.ciphertextSize,
        durationMs: prepared.durationMs,
        waveform: prepared.waveform,
        transcript: nil
      )
      cancelOrDiscard()
      return embed
    } catch {
      logger.error("Voice upload failed: \(error.localizedDescription)")
      voiceError = String(localized: "Failed to upload voice message: \(error.localizedDescription)", comment: "Error when uploading an encrypted voice message fails. %@ is the error description.")
      return nil
    }
  }

  nonisolated static func extractRawPcmBytes(fromWavData wavData: Data) -> Data {
    // Standard RIFF/WAVE header starts with "RIFF" <size:u32> "WAVE", followed by subchunks.
    if wavData.count > 12,
       String(data: wavData.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
       String(data: wavData.subdata(in: 8..<12), encoding: .ascii) == "WAVE"
    {
      var offset = 12
      while offset + 8 <= wavData.count {
        let chunkID = String(data: wavData.subdata(in: offset..<(offset + 4)), encoding: .ascii)
        let chunkSize = wavData.subdata(in: (offset + 4)..<(offset + 8)).withUnsafeBytes { raw -> Int in
          Int(raw.loadUnaligned(as: UInt32.self).littleEndian)
        }
        let payloadStart = offset + 8
        let payloadEnd = min(wavData.count, payloadStart + max(0, chunkSize))
        if chunkID == "data" {
          return wavData.subdata(in: payloadStart..<payloadEnd)
        }
        let paddedAdvance = chunkSize + (chunkSize % 2)
        guard paddedAdvance >= 0, payloadStart + paddedAdvance <= wavData.count else { break }
        offset = payloadStart + paddedAdvance
      }
    }
    return wavData
  }

  nonisolated private static func writeRawS16LEPcmFile(fromWavURL wavURL: URL) throws -> URL {
    let wavData = try Data(contentsOf: wavURL)
    let rawPcm = extractRawPcmBytes(fromWavData: wavData)
    let pcmURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("catbird-mls-voice-\(UUID().uuidString.lowercased()).pcm")
    try rawPcm.write(to: pcmURL, options: .atomic)
    return pcmURL
  }

  private func startDurationTimer() {
    stopDurationTimer()
    durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let start = self.recordingStartDate else { return }
        self.recordingDuration = Date().timeIntervalSince(start)
      }
    }
  }

  private func stopDurationTimer() {
    durationTimer?.invalidate()
    durationTimer = nil
  }

  private func archiveTempFile(_ url: URL?) {
    guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
    let trashDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("catbird-voice-trash", isDirectory: true)
    try? FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
    let dest = trashDir.appendingPathComponent("\(UUID().uuidString.lowercased())-\(url.lastPathComponent)")
    try? FileManager.default.moveItem(at: url, to: dest)
  }

  private static func requestMicrophonePermission() async -> Bool {
    if #available(iOS 17.0, macOS 14.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted:
        return true
      case .denied:
        return false
      case .undetermined:
        return await AVAudioApplication.requestRecordPermission()
      @unknown default:
        return false
      }
    } else {
      #if os(iOS)
      return await withCheckedContinuation { continuation in
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      }
      #else
      return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
      #endif
    }
  }
}

// MARK: - Pending Group Creation Recovery Banner (P1-1)

struct MLSPendingGroupCreationBanner: View {
  let status: PendingGroupCreationStatus
  var isBusy: Bool = false
  let onRetry: () -> Void
  let onCancel: () -> Void

  private var statusMessage: String {
    switch status.state {
    case .pendingRetry:
      return String(localized: "Finishing encrypted group setup. Catbird can retry right now or cancel.", comment: "Banner message when encrypted group creation is awaiting retry")
    case .needsUserAction:
      if let code = status.lastErrorCode, !code.isEmpty {
        return String(localized: "Encrypted group setup paused (\(code)). Retry or cancel this pending group.", comment: "Banner message when encrypted group creation paused with an error code. %@ is the error code.")
      }
      return String(localized: "Encrypted group setup needs your confirmation to retry or cancel.", comment: "Banner message when encrypted group creation requires user confirmation")
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Pending Encrypted Group Creation", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.orange)
      Text(statusMessage)
        .font(.footnote)
        .foregroundStyle(.secondary)
      HStack(spacing: 12) {
        Button {
          onRetry()
        } label: {
          Label("Retry Setup", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(isBusy)
        .accessibilityIdentifier("mls-pending-group-retry")

        Button(role: .destructive) {
          onCancel()
        } label: {
          Text("Cancel Group")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isBusy)
        .accessibilityIdentifier("mls-pending-group-cancel")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .accessibilityIdentifier("mls-pending-group-banner")
  }
}

// MARK: - Shared Participant & Group Configuration UI Components

struct MLSOptionalGroupIntroductionSection: View {
  @Binding var text: String

  var body: some View {
    Section {
      TextField("Optional invitation note", text: $text, axis: .vertical)
        .lineLimit(3...6)
      if text.utf8.count > 16_384 {
        Text("Use at most 16 KiB of text.")
          .foregroundStyle(.red)
      }
    } header: {
      Text("Separate encrypted introductions")
    } footer: {
      Text("The group is created first. You can then review and send this note separately to each selected invitee. Accepting a note never accepts the group invitation.")
    }
  }
}

struct ParticipantRow: View {
  let participant: MLSParticipantViewModel
  let isSelected: Bool
  var isMLSAvailable: Bool = true
  var showsEncryptionBadge: Bool = true
  var unavailableLabel: String = String(localized: "Not available", comment: "Badge label when a contact cannot be added to an encrypted chat")
  let onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(spacing: DesignTokens.Spacing.base) {
        ZStack(alignment: .bottomTrailing) {
          AsyncProfileImage(
            url: participant.avatarURL,
            size: DesignTokens.Size.avatarMD
          )

          if showsEncryptionBadge && isMLSAvailable {
            Image(systemName: "lock.shield.fill")
              .font(.system(size: 12))
              .foregroundColor(.green)
              .background(
                Circle()
                  #if os(iOS)
                  .fill(Color(.systemBackground))
                  #else
                  .fill(Color(nsColor: .windowBackgroundColor))
                  #endif
                  .frame(width: 16, height: 16)
              )
              .offset(x: 2, y: 2)
          }
        }

        VStack(alignment: .leading, spacing: 4) {
          if let displayName = participant.displayName {
            Text(displayName)
              .designCallout()
              .foregroundColor(.primary)
              .lineLimit(1)
          }

          HStack(spacing: 4) {
            Text(verbatim: "@\(participant.handle)")
              .designCaption()
              .foregroundColor(.secondary)
              .lineLimit(1)

            if !isMLSAvailable {
              Text("• \(unavailableLabel)", comment: "Inline unavailability badge next to a contact handle. %@ is the unavailability reason.")
                .designCaption()
                .foregroundColor(.orange)
            }
          }
        }

        Spacer()

        if isMLSAvailable {
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 24))
            .foregroundColor(isSelected ? .accentColor : .secondary.opacity(0.3))
            .animation(.spring(response: 0.3), value: isSelected)
        } else {
          Image(systemName: "xmark.circle")
            .font(.system(size: 24))
            .foregroundColor(.secondary.opacity(0.3))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct ParticipantChip: View {
  let participant: MLSParticipantViewModel
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      AsyncProfileImage(
        url: participant.avatarURL,
        size: 28
      )

      Text(participant.displayName ?? participant.handle)
        .designCaption()
        .lineLimit(1)

      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 16))
          .foregroundColor(.secondary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color.secondary.opacity(0.15))
    .cornerRadius(20)
  }
}

struct SelectedParticipantsSummaryList: View {
  let participants: [MLSParticipantViewModel]

  var body: some View {
    if participants.isEmpty {
      Text("No participants selected")
        .designCaption()
        .foregroundColor(.secondary)
    } else {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        ForEach(participants, id: \.id) { participant in
          HStack(spacing: DesignTokens.Spacing.base) {
            AsyncProfileImage(
              url: participant.avatarURL,
              size: DesignTokens.Size.avatarSM
            )

            VStack(alignment: .leading, spacing: 2) {
              Text(participant.displayName ?? participant.handle)
                .designCallout()
                .foregroundColor(.primary)
                .lineLimit(1)
              Text(verbatim: "@\(participant.handle)")
                .designCaption()
                .foregroundColor(.secondary)
                .lineLimit(1)
            }
            Spacer()
          }
        }
      }
    }
  }
}

struct EmptyStateRow: View {
  let icon: String
  let message: String

  var body: some View {
    HStack {
      Spacer()
      VStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: 32))
          .foregroundColor(.secondary.opacity(0.5))
        Text(message)
          .designCallout()
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(.vertical, 32)
      Spacer()
    }
  }
}
