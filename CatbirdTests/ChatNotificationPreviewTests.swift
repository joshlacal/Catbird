import CatbirdMLSCore
import Foundation
import Testing
import UserNotifications

@testable import Catbird

/// The "Show Encrypted Message Text" preference and what the Notification Service Extension
/// shows for a message it decrypted from the push alone.
@Suite("Chat Notification Previews")
struct ChatNotificationPreviewTests {
  private static let accountDID = "did:plc:previewaccount01"

  private func scratchDefaults() -> UserDefaults {
    let suite = "ChatNotificationPreviewTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  private func wake(recipientHash: String) -> PushWakePayload {
    PushWakePayload(
      kind: "applicationMessage",
      conversationId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
      generation: 0,
      entrySeq: 7,
      messageId: "msg-7",
      recipientAccountHash: recipientHash,
      fetchRequired: false,
      senderDid: nil,
      inlineCiphertext: Data([0x01])
    )
  }

  @Test("Previews are on until the user turns them off, per account")
  func preferenceDefaultsOnAndIsPerAccount() throws {
    let defaults = scratchDefaults()
    let hash = try MLSAppGroupStorage.accountDidHash(for: Self.accountDID)
    let otherHash = try MLSAppGroupStorage.accountDidHash(for: "did:plc:previewaccount02")

    #expect(MLSAccountPreferenceKeys.showsChatNotificationPreviews(accountHash: hash, defaults: defaults))
    #expect(NotificationManager.loadMLSChatNotificationPreviewPreference(
      accountDID: Self.accountDID, defaults: defaults))

    NotificationManager.storeMLSChatNotificationPreviewPreference(
      false, accountDID: Self.accountDID, defaults: defaults)

    // The extension reads the same key by the hash the push carries.
    #expect(!MLSAccountPreferenceKeys.showsChatNotificationPreviews(accountHash: hash, defaults: defaults))
    #expect(!MLSAccountPreferenceKeys.showsChatNotificationPreviews(
      accountHash: hash.uppercased(), defaults: defaults))
    #expect(!NotificationManager.loadMLSChatNotificationPreviewPreference(
      accountDID: Self.accountDID, defaults: defaults))
    #expect(MLSAccountPreferenceKeys.showsChatNotificationPreviews(accountHash: otherHash, defaults: defaults))

    NotificationManager.storeMLSChatNotificationPreviewPreference(
      true, accountDID: Self.accountDID, defaults: defaults)
    #expect(MLSAccountPreferenceKeys.showsChatNotificationPreviews(accountHash: hash, defaults: defaults))
  }

  @Test("A message decrypted from the push alone shows its sender and text")
  func unsequencedPreviewIsShown() throws {
    let hash = try MLSAppGroupStorage.accountDidHash(for: Self.accountDID)
    let wake = wake(recipientHash: hash)
    let preview = NotificationPreview(
      messageId: "b0b00000-0000-4000-8000-000000000010",
      conversationId: wake.conversationId,
      senderDid: "did:plc:previewsender01",
      senderDisplayName: "Robin",
      groupTitle: nil,
      body: "See you at six",
      epoch: 3,
      seq: 7,
      fromCache: false,
      fallbackGeneric: false,
      darwinNotificationName: MLSAppGroupStorage.nseDidCommitDarwinNotification,
      receiptVerified: false,
      isOwnSiblingSender: false
    )

    let shown = NotificationService.buildCommunicationNotification(
      base: UNMutableNotificationContent(),
      preview: preview,
      wake: wake,
      recipientAccountDID: Self.accountDID
    )
    #expect(shown.title == "Robin")
    #expect(shown.body == "See you at six")
    #expect(shown.userInfo["convo_id"] as? String == wake.conversationId)
    #expect(shown.userInfo["message_id"] as? String == preview.messageId)
    #expect(shown.userInfo["recipient_account"] as? String == hash)
  }

  @Test("A message from the account's own other device is quieted, receipt or not")
  func unsequencedOwnDeviceMessageIsQuieted() throws {
    let hash = try MLSAppGroupStorage.accountDidHash(for: Self.accountDID)
    let wake = wake(recipientHash: hash)
    let preview = NotificationPreview(
      messageId: "b0b00000-0000-4000-8000-000000000011",
      conversationId: wake.conversationId,
      senderDid: Self.accountDID,
      senderDisplayName: "Me",
      groupTitle: "Weekend",
      body: "Sent from my Mac",
      epoch: 3,
      seq: 7,
      fromCache: false,
      fallbackGeneric: false,
      darwinNotificationName: MLSAppGroupStorage.nseDidCommitDarwinNotification,
      receiptVerified: false,
      isOwnSiblingSender: true
    )

    let quieted = NotificationService.buildCommunicationNotification(
      base: UNMutableNotificationContent(),
      preview: preview,
      wake: wake,
      recipientAccountDID: Self.accountDID
    )
    #expect(quieted.body == "Synced message from your other device")
    #expect(quieted.sound == nil)
    #expect(quieted.userInfo["suppressedForOwnSiblingDevice"] as? Bool == true)
  }

  @Test("With previews off the alert carries routing only")
  func genericNotificationCarriesNoMessageContent() throws {
    let hash = try MLSAppGroupStorage.accountDidHash(for: Self.accountDID)
    let wake = wake(recipientHash: hash)

    let generic = NotificationService.genericChatNotification(
      base: UNMutableNotificationContent(), wake: wake)
    #expect(generic.title == "Catbird")
    #expect(generic.body == MLSPushExtensionProcessor.genericFallbackBody)
    #expect(generic.userInfo["type"] as? String == "mls_message")
    #expect(generic.userInfo["convo_id"] as? String == wake.conversationId)
    #expect(generic.userInfo["recipient_account"] as? String == hash)
    #expect(generic.userInfo["message_id"] == nil)
  }
}
