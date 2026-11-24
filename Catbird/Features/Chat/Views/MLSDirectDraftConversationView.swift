import CatbirdMLSCore
import Foundation
import Petrel
import SwiftUI

/// The Chat tab's selection for a one-to-one encrypted chat that does not exist yet.
///
/// A new one-to-one chat is created by its first message, so until that is sent there is no
/// conversation ID to select. The tab selects this stand-in instead and shows the chat
/// screen for the person; sending replaces the selection with the real conversation.
enum MLSDirectDraftRoute {
  static let prefix = "mls-direct-draft:"

  static func selectionID(recipientDID: String) -> String {
    prefix + recipientDID
  }

  /// The recipient of a draft selection, or nil when `selectionID` names a real conversation.
  static func recipientDID(fromSelectionID selectionID: String) -> String? {
    guard selectionID.hasPrefix(prefix) else { return nil }
    let did = String(selectionID.dropFirst(prefix.count))
    return did.hasPrefix("did:") ? did : nil
  }
}

#if os(iOS)

/// The chat screen for a person you have no encrypted chat with yet.
///
/// It looks like the conversation it will become: the person's name in the title, their
/// profile at the top of an empty transcript and a composer at the bottom. The first message
/// creates the chat request; the screen then hands over to the real conversation.
struct MLSDirectDraftConversationView: View {
  @Environment(AppState.self) private var appState
  @Environment(SceneNavigationContext.self) private var sceneContext

  let recipientDID: String
  /// Called with the conversation to show once the first message has created it.
  let onOpenConversation: (String) -> Void

  @State private var recipient: NewConversationRecipient?
  @State private var messageText = ""
  @State private var isSending = false
  @State private var errorMessage: String?
  /// A chat that already exists with this person and is waiting on a request.
  @State private var waitingConversationID: String?
  @State private var recipientCapability: MLSChatCapability?
  @FocusState private var composerFocused: Bool

  private var title: String {
    if let displayName = recipient?.displayName, !displayName.isEmpty { return displayName }
    if let handle = recipient?.handle, !handle.isEmpty { return "@\(handle)" }
    return String(localized: "Encrypted Chat", comment: "Fallback navigation title for an unnamed MLS encrypted chat")
  }

  private var canSend: Bool {
    MLSDirectComposeSendGate.canSend(
      text: messageText, capability: recipientCapability, isSubmitting: isSending)
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        profileHeader
        if let capability = recipientCapability, let notice = ChatFailureMessage.text(for: capability) {
          noticeCard(notice) {
            if case .unknown = capability {
              Button("Try again") {
                Task { await checkRecipient(forceRefresh: true) }
              }
              .disabled(isSending)
            }
          }
        }
        if let errorMessage {
          noticeCard(errorMessage, isError: waitingConversationID == nil) {
            if let waitingConversationID {
              Button("Open Chat") { onOpenConversation(waitingConversationID) }
            }
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 32)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
    .safeAreaInset(edge: .bottom) { composer }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        HStack(spacing: 4) {
          Image(systemName: "lock.fill")
            .font(.caption)
            .foregroundStyle(.green)
            .accessibilityHidden(true)
          Text(title)
            .font(.headline)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          Text(
            "\(title), encrypted chat",
            comment: "Accessibility label for encrypted chat header. %@ is the conversation title."
          )
        )
        .accessibilityIdentifier("chat.header.encrypted")
      }
    }
    .task(id: "\(appState.userDID):\(recipientDID)") {
      loadDraft()
      async let profile: Void = loadRecipient()
      async let capability: Void = checkRecipient(forceRefresh: false)
      _ = await (profile, capability)
    }
    .onChange(of: messageText) { _, newValue in
      saveDraft(text: newValue)
    }
  }

  // MARK: - Header

  private var profileHeader: some View {
    VStack(spacing: 12) {
      Button {
        sceneContext.navigationManager.navigate(
          to: .profile(recipientDID), in: AppNavigationManager.chatTabIndex)
      } label: {
        VStack(spacing: 8) {
          AsyncProfileImage(url: recipient?.avatarURL, size: 80, did: recipientDID)
          if let displayName = recipient?.displayName, !displayName.isEmpty {
            Text(displayName)
              .font(.title3.weight(.semibold))
              .foregroundStyle(.primary)
          }
          if let handle = recipient?.handle, !handle.isEmpty {
            Text(verbatim: "@\(handle)")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          } else if recipient == nil {
            ProgressView()
          }
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.plain)
      .accessibilityHint(Text("Opens their profile", comment: "Accessibility hint on the recipient header of a new encrypted chat"))

      Label {
        Text(
          "Messages are end-to-end encrypted. Your first message is sent as a chat request.",
          comment: "Explanation under the recipient's profile in a new encrypted chat"
        )
      } icon: {
        Image(systemName: "lock.fill")
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
    }
    .padding(.bottom, 4)
  }

  private func noticeCard<Actions: View>(
    _ text: String,
    isError: Bool = false,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
    VStack(spacing: 8) {
      Text(text)
        .font(.footnote)
        .foregroundStyle(isError ? Color.red : Color.secondary)
        .multilineTextAlignment(.center)
      actions()
        .font(.footnote.weight(.semibold))
    }
    .padding(12)
    .frame(maxWidth: .infinity)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  // MARK: - Composer

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField(
        String(localized: "Encrypted message", comment: "Placeholder in the composer of a new encrypted chat"),
        text: $messageText,
        axis: .vertical
      )
      .lineLimit(1...6)
      .focused($composerFocused)
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .strokeBorder(Color.secondary.opacity(0.3))
      )
      .accessibilityIdentifier("mlsDirectDraft.composer")

      Button {
        Task { await send() }
      } label: {
        if isSending {
          ProgressView()
            .frame(width: 32, height: 32)
        } else {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 32))
        }
      }
      .disabled(!canSend)
      .accessibilityLabel(Text("Send", comment: "Send button in a new encrypted chat"))
      .accessibilityIdentifier("mlsDirectDraft.send")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.bar)
  }

  // MARK: - Loading

  @MainActor
  private func loadDraft() {
    let draft = MLSDirectComposeDraftStore.open(accountDID: appState.userDID, recipientDID: recipientDID)
    if messageText.isEmpty { messageText = draft.text }
    if recipient == nil, let handle = draft.recipientHandle {
      recipient = NewConversationRecipient(
        did: recipientDID,
        handle: handle,
        displayName: draft.recipientDisplayName,
        avatarURL: draft.recipientAvatarURL
      )
    }
  }

  @MainActor
  private func saveDraft(text: String) {
    var draft = MLSDirectComposeDraftStore.open(accountDID: appState.userDID, recipientDID: recipientDID)
    guard !draft.submitted else { return }
    draft.text = text
    MLSDirectComposeDraftStore.save(draft)
  }

  /// Fetches the person's profile so the screen never shows a bare DID.
  @MainActor
  private func loadRecipient() async {
    let accountDID = appState.userDID
    guard let client = appState.atProtoClient,
          let actor = try? ATIdentifier(string: recipientDID) else { return }
    let response = try? await client.app.bsky.actor.getProfile(
      input: AppBskyActorGetProfile.Parameters(actor: actor))
    guard let profile = response?.1 else { return }
    guard !Task.isCancelled, appState.userDID == accountDID else { return }
    let loaded = NewConversationRecipient(profile: profile)
    recipient = loaded
    var draft = MLSDirectComposeDraftStore.open(accountDID: accountDID, recipientDID: recipientDID)
    draft.recipientHandle = loaded.handle
    draft.recipientDisplayName = loaded.displayName
    draft.recipientAvatarURL = loaded.avatarURL
    MLSDirectComposeDraftStore.save(draft)
  }

  @MainActor
  private func checkRecipient(forceRefresh: Bool) async {
    let accountDID = appState.userDID
    let result = await MLSChatCapabilityResolver.shared.capability(
      for: recipientDID, forceRefresh: forceRefresh)
    guard !Task.isCancelled, appState.userDID == accountDID else { return }
    recipientCapability = result
  }

  // MARK: - Sending

  @MainActor
  private func send() async {
    let accountDID = appState.userDID
    guard canSend else { return }
    let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    isSending = true
    defer { isSending = false }
    errorMessage = nil
    waitingConversationID = nil
    do {
      try MLSDirectComposeDraftStore.validateText(trimmed)
      await checkRecipient(forceRefresh: true)
      guard !Task.isCancelled, appState.userDID == accountDID,
            recipientCapability?.isCapable == true else { return }
      guard let coordinator = await appState.getOrOpenMLSCoordinator() else {
        errorMessage = String(
          localized: "Encrypted chat isn’t ready on this device yet. Try again in a moment.",
          comment: "Error when the MLS coordinator is not yet ready")
        return
      }
      guard !Task.isCancelled, appState.userDID == accountDID else { return }
      let outcome = try await MLSDirectChatStart.start(
        coordinator: coordinator,
        sequencerDID: appState.defaultMLSSequencerDID,
        recipientDID: recipientDID,
        text: trimmed
      )
      guard !Task.isCancelled, appState.userDID == accountDID else { return }
      if let notice = outcome.delivery.notice {
        // The text was not delivered; keep it here, say why and offer the waiting chat.
        errorMessage = notice
        waitingConversationID = outcome.conversationID
        return
      }
      let draft = MLSDirectComposeDraftStore.open(accountDID: accountDID, recipientDID: recipientDID)
      MLSDirectComposeDraftStore.archive(draft)
      messageText = ""
      onOpenConversation(outcome.conversationID)
    } catch {
      guard appState.userDID == accountDID else { return }
      errorMessage = ChatFailureMessage.text(for: error, context: .startEncryptedChat)
    }
  }
}

#endif
