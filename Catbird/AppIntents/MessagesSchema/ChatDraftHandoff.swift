//
//  ChatDraftHandoff.swift
//  Catbird
//
//  Carries a chat draft from an App Intent (Siri / Shortcuts) into the chat
//  composer. Drafts remain unclaimed until the route is accepted by the
//  intended account and scene. A composer inspects a draft before claiming
//  that exact token, so an unavailable target does not discard its text.
//

import Foundation

struct PendingChatDraft: Codable, Sendable, Equatable {
  let id: UUID
  let accountDID: String
  /// Captured scene when staged; the exact receiving scene after binding.
  let sceneID: UUID?
  /// `nil` lets the user choose a conversation within the bound scene.
  let conversationID: String?
  let text: String

  init(
    id: UUID = UUID(),
    accountDID: String,
    sceneID: UUID? = nil,
    conversationID: String?,
    text: String
  ) {
    self.id = id
    self.accountDID = accountDID
    self.sceneID = sceneID
    self.conversationID = conversationID
    self.text = text
  }
}

@MainActor
final class ChatDraftHandoff {
  static let shared = ChatDraftHandoff()

  /// Posted only after a route has bound a draft to its receiving scene.
  /// Observers must still match the scene, account, conversation, and token.
  static let didStoreDraft = Notification.Name("ChatDraftHandoff.didStoreDraft")

  private struct Entry {
    let staged: PendingChatDraft
    var bound: PendingChatDraft?
    var isPublished = false
    var deliveryInvalidated = false
  }

  typealias Publication = @MainActor @Sendable () -> Void
  typealias PublicationScheduler = @MainActor (@escaping Publication) -> Void
  private var entries: [UUID: Entry] = [:]
  private var order: [UUID] = []
  private var consumedDrafts: [UUID: PendingChatDraft] = [:]
  private let schedulePublication: PublicationScheduler

  init(schedulePublication: @escaping PublicationScheduler = { publication in
    Task { @MainActor in publication() }
  }) {
    self.schedulePublication = schedulePublication
  }

  /// Staging never makes a draft consumable, even when its scene is known.
  /// Repeated storage of the same token is idempotent; different text or scope
  /// cannot replace an existing handoff.
  @discardableResult
  func store(_ draft: PendingChatDraft) -> Bool {
    guard consumedDrafts[draft.id] == nil else { return false }
    if let existing = entries[draft.id] {
      return existing.staged == draft
    }
    entries[draft.id] = Entry(staged: draft)
    order.append(draft.id)
    return true
  }

  /// Called synchronously by the route's before-delivery callback. A captured
  /// scene may not change, and an unscoped draft may bind to only one scene.
  @discardableResult
  func bind(
    id: UUID,
    accountDID: String,
    sceneID: UUID,
    conversationID: String?
  ) -> PendingChatDraft? {
    guard var entry = entries[id], !entry.deliveryInvalidated,
      entry.staged.accountDID == accountDID,
      entry.staged.sceneID == nil || entry.staged.sceneID == sceneID,
      entry.staged.conversationID == nil || entry.staged.conversationID == conversationID
    else { return nil }

    if let bound = entry.bound {
      guard bound.sceneID == sceneID, bound.conversationID == conversationID else { return nil }
      return bound
    }

    let bound = PendingChatDraft(
      id: id,
      accountDID: accountDID,
      sceneID: sceneID,
      conversationID: conversationID,
      text: entry.staged.text
    )
    entry.bound = bound
    entries[id] = entry
    // Navigation's selection callbacks run synchronously after binding and may
    // invalidate this scene. Publish only after that delivery stack returns.
    schedulePublication { [weak self] in
      guard let self, var current = self.entries[id], !current.deliveryInvalidated,
        !current.isPublished, current.bound == bound
      else { return }
      current.isPublished = true
      self.entries[id] = current
      NotificationCenter.default.post(name: Self.didStoreDraft, object: self)
    }
    return bound
  }

  /// Returns the oldest eligible draft without removing it. An occupied or
  /// unavailable composer can leave the draft pending and try again later.
  func peek(sceneID: UUID, accountDID: String, conversationID: String) -> PendingChatDraft? {
    for id in order {
      guard let entry = entries[id], entry.isPublished,
        !entry.deliveryInvalidated, let draft = entry.bound,
        draft.sceneID == sceneID,
        draft.accountDID == accountDID,
        draft.conversationID == nil || draft.conversationID == conversationID
      else { continue }
      return draft
    }
    return nil
  }

  /// Claims only the draft the composer already inspected. A stale callback
  /// cannot consume a newer queued draft or a draft belonging to another view.
  func consume(
    sceneID: UUID,
    accountDID: String,
    conversationID: String,
    expectedID: UUID
  ) -> PendingChatDraft? {
    guard let draft = peek(
      sceneID: sceneID, accountDID: accountDID, conversationID: conversationID
    ), draft.id == expectedID else { return nil }
    entries.removeValue(forKey: expectedID)
    order.removeAll { $0 == expectedID }
    consumedDrafts[expectedID] = draft
    return draft
  }

  /// Account replacement or scene disconnection revokes delivery without
  /// deleting text. A replacement context cannot revive the original token.
  func invalidate(sceneID: UUID, accountDID: String) {
    for id in order {
      guard var entry = entries[id], entry.staged.accountDID == accountDID,
        entry.bound?.sceneID == sceneID || entry.staged.sceneID == sceneID
      else { continue }
      entry.deliveryInvalidated = true
      entries[id] = entry
    }
  }

  /// Inspection for explicit recovery; it does not grant delivery or remove
  /// anything. Recovery must create a new token with a newly chosen scene.
  func retainedDraft(id: UUID, accountDID: String) -> PendingChatDraft? {
    if let entry = entries[id], entry.staged.accountDID == accountDID {
      return entry.bound ?? entry.staged
    }
    guard let consumed = consumedDrafts[id], consumed.accountDID == accountDID else { return nil }
    return consumed
  }
}
