import CatbirdMLSCore
import CryptoKit
import Foundation
import Intents
import UserNotifications

/// Clean-slate `NotificationServiceExtension` (`Spec §6.2`, `G1`, `I7`, `I10–I12`) +
/// signed-out push suppression (`PR #60`).
///
/// Zero `GRDB`, zero Tokio pool, `< 15 MB` peak RSS: neutralizes gated-off or signed-out
/// account pushes before touching storage, enriches plaintext Bluesky `chat_message` pushes
/// from the read-only SQLite3 profile cache, and delegates MLS decryption, gap catch-up,
/// SQLite `BEGIN IMMEDIATE` commit + handle close, and `blue.catbird.mls.nseDidCommit`
/// Darwin wakeup to `MLSPushExtensionProcessor.process(...)`.
class NotificationService: UNNotificationServiceExtension {
  private static let appGroupSuite = MLSAppGroupStorage.appGroupIdentifier

  /// App Group keys the main app publishes for push presence (`SignedOutPushSuppression`).
  static let signedOutKey = "signedOutForPush"
  static let pushActiveAccountDIDKey = "pushActiveAccountDID"
  static let sessionEndedAccountDIDsKey = "sessionEndedPushAccountDIDs"

  private let appGroupDefaults: UserDefaults?
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?

  override init() {
    appGroupDefaults = UserDefaults(suiteName: Self.appGroupSuite)
    super.init()
  }

  init(appGroupDefaults: UserDefaults?) {
    self.appGroupDefaults = appGroupDefaults
    super.init()
  }

  private static func isGatedOff(pushType: String?, kind: String?) -> Bool {
    if let pushType, pushType.hasPrefix("mls_"), !CatbirdFeatures.mlsChat {
      return true
    }
    if kind == "circle_activity", !CatbirdFeatures.circlesSpaces {
      return true
    }
    return false
  }

  static func isAddressedToSignedOutAccount(recipientDID: String?, defaults: UserDefaults?) -> Bool {
    guard let defaults else { return false }
    if defaults.bool(forKey: signedOutKey) {
      return true
    }
    guard let recipientDID, !recipientDID.isEmpty,
      recipientDID != defaults.string(forKey: pushActiveAccountDIDKey)
    else {
      return false
    }
    let endedDIDs = defaults.stringArray(forKey: sessionEndedAccountDIDsKey) ?? []
    return endedDIDs.contains(recipientDID)
  }

  private static func neutralizedForSignedOutAccount(_ original: UNMutableNotificationContent)
    -> UNMutableNotificationContent
  {
    let content = UNMutableNotificationContent()
    content.title = "Catbird"
    content.subtitle = ""
    content.body = "New activity"
    content.sound = nil
    content.badge = nil
    content.interruptionLevel = .passive
    content.relevanceScore = 0
    content.attachments = []
    content.threadIdentifier = "catbird-suppressed"
    content.categoryIdentifier = ""
    content.targetContentIdentifier = nil
    #if os(iOS)
    content.launchImageName = ""
    #endif

    var userInfo: [AnyHashable: Any] = ["suppressedForSignedOutAccount": true]
    if let type = original.userInfo["type"] as? String { userInfo["type"] = type }
    if let kind = original.userInfo["kind"] as? String { userInfo["kind"] = kind }
    content.userInfo = userInfo
    return content
  }

  private static func neutralized(_ original: UNMutableNotificationContent)
    -> UNMutableNotificationContent
  {
    let content = UNMutableNotificationContent()
    content.title = "Catbird"
    content.body = "New activity"
    content.sound = nil
    content.interruptionLevel = .passive
    content.threadIdentifier = "catbird-unsupported"
    var userInfo: [AnyHashable: Any] = [:]
    if let type = original.userInfo["type"] as? String { userInfo["type"] = type }
    if let kind = original.userInfo["kind"] as? String { userInfo["kind"] = kind }
    content.userInfo = userInfo
    return content
  }

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    guard let mutable = request.content.mutableCopy() as? UNMutableNotificationContent else {
      contentHandler(request.content)
      return
    }
    self.bestAttemptContent = mutable

    let userInfo = request.content.userInfo
    let rawType = userInfo["type"] as? String
    let rawKind = userInfo["kind"] as? String

    if Self.isGatedOff(pushType: rawType, kind: rawKind) {
      contentHandler(Self.neutralized(mutable))
      return
    }

    let resolvedRecipientDID = resolveChatRecipientDID(from: userInfo)
    if Self.isAddressedToSignedOutAccount(recipientDID: resolvedRecipientDID, defaults: appGroupDefaults) {
      contentHandler(Self.neutralizedForSignedOutAccount(mutable))
      return
    }

    let pushType = rawType ?? rawKind
    if pushType == "chat_message" {
      Task {
        await self.enrichBlueskyChatPush(
          mutable,
          userInfo: userInfo,
          resolvedRecipientDID: resolvedRecipientDID,
          contentHandler: contentHandler
        )
      }
      return
    }

    guard let wake = Self.decodePushWakePayload(from: userInfo) else {
      contentHandler(mutable)
      return
    }

    if let wakeRecipient = resolvePublishedAccountDID(fromHash: wake.recipientAccountHash),
       Self.isAddressedToSignedOutAccount(recipientDID: wakeRecipient, defaults: appGroupDefaults)
    {
      contentHandler(Self.neutralizedForSignedOutAccount(mutable))
      return
    }

    guard let appGroupRoot = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: Self.appGroupSuite
    ) else {
      Self.applyFallback(to: mutable, wake: wake)
      contentHandler(mutable)
      return
    }

    if let enabled = appGroupDefaults?.object(forKey: "mlsChatNotificationsEnabled_\(wake.recipientAccountHash)") as? Bool,
       !enabled
    {
      contentHandler(mutable)
      return
    }

    let homeDsURL = appGroupDefaults?
      .string(forKey: "mlsHomeDsEndpoint_\(wake.recipientAccountHash)")
      .flatMap(URL.init(string:)) ?? URL(string: "https://chat.catbird.blue")

    let preview = MLSPushExtensionProcessor.process(
      storageRoot: appGroupRoot,
      accountDidHash: wake.recipientAccountHash,
      keystore: KeychainPlatformKeyStore(),
      transport: PetrelPlatformTransport(homeDsEndpoint: homeDsURL),
      wake: wake,
      postDarwinNotification: true
    )

    contentHandler(Self.buildCommunicationNotification(base: mutable, preview: preview, wake: wake))
  }

  override func serviceExtensionTimeWillExpire() {
    guard let handler = contentHandler, let content = bestAttemptContent else { return }
    if content.body.isEmpty {
      content.title = "Catbird"
      content.body = MLSPushExtensionProcessor.genericFallbackBody
    }
    handler(content)
  }

  private func enrichBlueskyChatPush(
    _ content: UNMutableNotificationContent,
    userInfo: [AnyHashable: Any],
    resolvedRecipientDID: String?,
    contentHandler: @escaping (UNNotificationContent) -> Void
  ) async {
    let senderDid = userInfo["senderDid"] as? String
    let convoId = userInfo["convoId"] as? String
    let messageText = userInfo["messageText"] as? String

    if let senderDid, let cached = await ProfileCacheDatabase.shared.read(did: senderDid) {
      content.title = cached.displayName ?? cached.handle
    } else if content.title.isEmpty {
      content.title = "New Message"
    }
    content.body = (messageText?.isEmpty == false) ? messageText! : "Sent you a message"
    if let convoId { content.threadIdentifier = "chat:\(convoId)" }
    content.categoryIdentifier = "CHAT_MESSAGE"

    var updatedInfo = content.userInfo
    if let resolvedRecipientDID {
      updatedInfo["recipientDid"] = resolvedRecipientDID
    } else {
      updatedInfo.removeValue(forKey: "recipientDid")
    }
    content.userInfo = updatedInfo
    contentHandler(content)
  }

  private func resolveChatRecipientDID(from userInfo: [AnyHashable: Any]) -> String? {
    if let did = userInfo["recipientDid"] as? String, !did.isEmpty {
      return did
    }
    if let did = userInfo["recipient_did"] as? String, !did.isEmpty {
      return did
    }
    if let hash = userInfo["recipient_account"] as? String {
      return resolvePublishedAccountDID(fromHash: hash)
    }
    return nil
  }

  private func resolvePublishedAccountDID(fromHash hash: String) -> String? {
    let normalizedHash = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalizedHash.count == 64 else { return nil }
    var candidates = appGroupDefaults?.stringArray(forKey: "knownAccountDIDs") ?? []
    if let ended = appGroupDefaults?.stringArray(forKey: Self.sessionEndedAccountDIDsKey) {
      for did in ended where !candidates.contains(did) {
        candidates.append(did)
      }
    }
    for did in candidates {
      let forms = [did, did.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
      for form in forms where Self.sha256Hex(form) == normalizedHash {
        return did
      }
    }
    return nil
  }

  private static func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func decodePushWakePayload(from userInfo: [AnyHashable: Any]) -> PushWakePayload? {
    let dict: [String: Any]
    if let nested = userInfo["payload"] as? [String: Any] {
      dict = nested
    } else if let jsonStr = userInfo["payload"] as? String,
              let data = jsonStr.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    {
      dict = parsed
    } else {
      dict = Dictionary(uniqueKeysWithValues: userInfo.compactMap { k, v in
        (k as? String).map { ($0, v) }
      })
    }

    guard let rawConvo = (dict["conversationId"] as? String) ?? (dict["convo_id"] as? String),
          let rawHash = (dict["recipientAccountHash"] as? String) ?? (dict["recipient_account"] as? String),
          !rawConvo.isEmpty,
          !rawHash.isEmpty
    else { return nil }

    let kind = (dict["kind"] as? String) ?? (dict["type"] as? String) ?? "application"
    let generation = (dict["generation"] as? Int64) ?? (dict["generation"] as? Int).map(Int64.init) ?? 0
    let entrySeq = (dict["entrySeq"] as? Int64) ?? (dict["seq"] as? Int64) ?? (dict["seq"] as? String).flatMap(Int64.init) ?? 0
    let messageId = (dict["messageId"] as? String) ?? (dict["message_id"] as? String) ?? "msg-\(entrySeq)"
    let senderDid = (dict["senderDid"] as? String) ?? (dict["sender_did"] as? String)
    let inlineCiphertext = (dict["ciphertext"] as? String).flatMap { Data(base64Encoded: $0) }
    let fetchRequired = (dict["fetchRequired"] as? Bool) ?? (inlineCiphertext == nil)

    return PushWakePayload(
      kind: kind,
      conversationId: rawConvo,
      generation: generation,
      entrySeq: entrySeq,
      messageId: messageId,
      recipientAccountHash: rawHash.lowercased(),
      fetchRequired: fetchRequired,
      senderDid: senderDid,
      inlineCiphertext: inlineCiphertext
    )
  }

  private static func applyFallback(to content: UNMutableNotificationContent, wake: PushWakePayload) {
    content.title = wake.kind.contains("request") ? "Message Request" : "Catbird"
    content.body = MLSPushExtensionProcessor.genericFallbackBody
    content.threadIdentifier = "mls-\(wake.conversationId)"
    content.categoryIdentifier = "MLS_MESSAGE"
  }

  private static func buildCommunicationNotification(
    base: UNMutableNotificationContent,
    preview: NotificationPreview,
    wake: PushWakePayload
  ) -> UNNotificationContent {
    let senderName = preview.senderDisplayName ?? "Catbird"
    base.title = preview.groupTitle ?? senderName
    base.body = preview.body
    base.threadIdentifier = "mls-\(preview.conversationId)"
    base.categoryIdentifier = "MLS_MESSAGE"
    var info = base.userInfo
    info["type"] = wake.kind.contains("request") ? "mls_message_request" : "mls_message"
    info["protocol_version"] = "2"
    info["convo_id"] = preview.conversationId
    info["message_id"] = preview.messageId
    info["recipient_account"] = wake.recipientAccountHash
    base.userInfo = info

    guard !preview.fallbackGeneric else { return base }

    let senderId = preview.senderDid.isEmpty ? preview.conversationId : preview.senderDid
    let sender = INPerson(
      personHandle: INPersonHandle(value: senderId, type: .unknown),
      nameComponents: nil,
      displayName: senderName,
      image: nil,
      contactIdentifier: nil,
      customIdentifier: senderId
    )
    let intent = INSendMessageIntent(
      recipients: nil,
      outgoingMessageType: .outgoingMessageText,
      content: preview.body,
      speakableGroupName: preview.groupTitle.map(INSpeakableString.init(spokenPhrase:)),
      conversationIdentifier: preview.conversationId,
      serviceName: "Catbird",
      sender: sender,
      attachments: nil
    )
    return (try? base.updating(from: intent)) ?? base
  }
}
