//
//  ChatDraftHandoff.swift
//  Catbird
//
//  Carries a chat draft from an App Intent (Siri / Shortcuts) into the chat
//  composer. The intent process stores the draft and navigates; the
//  conversation view consumes it when it appears (or immediately, via the
//  notification, if it is already on screen).
//

import Foundation

struct PendingChatDraft: Sendable, Equatable {
  /// Conversation the draft targets. `nil` means "next conversation the user
  /// opens" (draft had no resolvable destination).
  let conversationID: String?
  let text: String
}

@MainActor
final class ChatDraftHandoff {
  static let shared = ChatDraftHandoff()

  /// Posted after `store(_:)` so an already-visible conversation view can
  /// consume the draft without waiting for a fresh `onAppear`.
  static let didStoreDraft = Notification.Name("ChatDraftHandoff.didStoreDraft")

  private(set) var pending: PendingChatDraft?

  private init() {}

  func store(_ draft: PendingChatDraft) {
    pending = draft
    NotificationCenter.default.post(name: Self.didStoreDraft, object: nil)
  }

  /// Returns the pending draft text if it targets `conversationID` (or is a
  /// wildcard draft), clearing it so it is applied exactly once.
  func consume(for conversationID: String) -> String? {
    guard let pending else { return nil }
    guard pending.conversationID == nil || pending.conversationID == conversationID else {
      return nil
    }
    self.pending = nil
    return pending.text
  }
}

