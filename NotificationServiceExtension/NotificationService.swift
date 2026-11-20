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

  /// Whether the user turned encrypted chat off for the account the wake is addressed to.
  static func isMLSDisabledByUser(accountHash: String, defaults: UserDefaults?) -> Bool {
    defaults?.bool(forKey: MLSAccountPreferenceKeys.userDisabled(accountHash: accountHash)) ?? false
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

    let wake = MLSPushExtensionProcessor.decodePushWakePayload(from: userInfo)
    let resolvedRecipientDID = resolveChatRecipientDID(from: userInfo, wake: wake)
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

    guard let wake else {
      contentHandler(mutable)
      return
    }

    let wakeRecipient = resolvePublishedAccountDID(fromHash: wake.recipientAccountHash)
    if let wakeRecipient,
       Self.isAddressedToSignedOutAccount(recipientDID: wakeRecipient, defaults: appGroupDefaults)
    {
      contentHandler(Self.neutralizedForSignedOutAccount(mutable))
      return
    }

    if Self.isMLSDisabledByUser(accountHash: wake.recipientAccountHash, defaults: appGroupDefaults) {
      contentHandler(Self.neutralized(mutable))
      return
    }

    guard let appGroupRoot = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: Self.appGroupSuite
    ) else {
      Self.applyFallback(to: mutable, wake: wake)
      contentHandler(mutable)
      return
    }

    if let enabled = appGroupDefaults?.object(
      forKey: MLSAccountPreferenceKeys.chatNotificationsEnabled(accountHash: wake.recipientAccountHash)
    ) as? Bool,
       !enabled
    {
      contentHandler(mutable)
      return
    }

    // Previews off: say only that a message arrived, and never open the account's chat keys.
    guard MLSAccountPreferenceKeys.showsChatNotificationPreviews(
      accountHash: wake.recipientAccountHash,
      defaults: appGroupDefaults
    ) else {
      contentHandler(Self.genericChatNotification(base: mutable, wake: wake))
      return
    }

    let homeDsURL = appGroupDefaults?
      .string(forKey: "mlsHomeDsEndpoint_\(wake.recipientAccountHash)")
      .flatMap(URL.init(string:)) ?? URL(string: "https://chat.catbird.blue")
    let ownPdsURL = appGroupDefaults?
      .string(forKey: "mlsPdsEndpoint_\(wake.recipientAccountHash)")
      .flatMap(URL.init(string:))
    let actorDeviceId = appGroupDefaults?
      .string(forKey: "mlsDeviceId_\(wake.recipientAccountHash)")

    let preview = MLSPushExtensionProcessor.process(
      storageRoot: appGroupRoot,
      accountDidHash: wake.recipientAccountHash,
      keystore: KeychainPlatformKeyStore(),
      transport: PetrelPlatformTransport(
        homeDsEndpoint: homeDsURL,
        ownPdsEndpoint: ownPdsURL,
        actorDeviceId: actorDeviceId
      ),
      wake: wake,
      postDarwinNotification: true
    )

    Task {
      let cachedSenderName = await Self.cachedSenderName(for: preview)
      if Self.presentsAsIncomingMessage(preview: preview, wake: wake, recipientAccountDID: wakeRecipient) {
        let interaction = INInteraction(
          intent: Self.incomingMessageIntent(
            preview: preview,
            senderName: Self.senderName(preview: preview, cachedSenderName: cachedSenderName)
          ),
          response: nil
        )
        interaction.direction = .incoming
        try? await interaction.donate()
      }
      contentHandler(
        Self.buildCommunicationNotification(
          base: mutable,
          preview: preview,
          wake: wake,
          recipientAccountDID: wakeRecipient,
          cachedSenderName: cachedSenderName
        )
      )
    }
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

  private func resolveChatRecipientDID(
    from userInfo: [AnyHashable: Any],
    wake: PushWakePayload?
  ) -> String? {
    if let did = userInfo["recipientDid"] as? String, !did.isEmpty {
      return did
    }
    if let did = userInfo["recipient_did"] as? String, !did.isEmpty {
      return did
    }
    if let hash = userInfo["recipient_account"] as? String {
      return resolvePublishedAccountDID(fromHash: hash)
    }
    // The gateway wake: version 1 carries the account hash in clear, version 2 seals it,
    // so both go through the decoder rather than reading the raw `catbird` object.
    if let wake {
      return resolvePublishedAccountDID(fromHash: wake.recipientAccountHash)
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

  private static func applyFallback(to content: UNMutableNotificationContent, wake: PushWakePayload) {
    content.title = wake.kind.contains("request") ? "Message Request" : "Catbird"
    content.body = MLSPushExtensionProcessor.genericFallbackBody
    content.threadIdentifier = "mls-\(wake.conversationId)"
    content.categoryIdentifier = "MLS_MESSAGE"
  }

  /// Strips any `#<deviceId>` credential fragment and normalizes an account DID for same-account checks.
  static func canonicalRootDID(_ did: String?) -> String {
    guard let did else { return "" }
    let trimmed = did.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let root = String(trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !root.isEmpty else { return "" }
    return ((try? MLSAppGroupStorage.canonicalizeAccountDid(root)) ?? root).lowercased()
  }

  static func isSameAccount(_ senderDID: String?, as recipientAccountDID: String?) -> Bool {
    let lhs = canonicalRootDID(senderDID)
    let rhs = canonicalRootDID(recipientAccountDID)
    return !lhs.isEmpty && lhs == rhs
  }

  /// Returns `true` when a decrypted MLS preview was authored by one of the recipient account's
  /// own sibling devices (matching either `recipientAccountDID` or `wake.recipientAccountHash`).
  /// A generic fallback names no authenticated sender, so it never counts.
  static func isOwnSiblingSender(
    preview: NotificationPreview,
    wake: PushWakePayload,
    recipientAccountDID: String? = nil
  ) -> Bool {
    guard !preview.fallbackGeneric else { return false }
    if preview.isOwnSiblingSender { return true }
    let senderRoot = canonicalRootDID(preview.senderDid)
    guard !senderRoot.isEmpty else { return false }
    if let recipientAccountDID, isSameAccount(senderRoot, as: recipientAccountDID) {
      return true
    }
    let normalizedHash = wake.recipientAccountHash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalizedHash.count == 64 && sha256Hex(senderRoot) == normalizedHash
  }

  /// Apple's managed `com.apple.developer.usernotifications.filtering` entitlement is NOT
  /// provisioned in `NotificationServiceExtension.entitlements`. Primary own-device push
  /// suppression is enforced server-side by excluding `sender_device_id` during push fanout;
  /// without the managed filtering entitlement, NSE cannot silently drop an APNs alert via an
  /// empty `UNNotificationContent()` (which iOS would otherwise render as a blank banner).
  static let hasManagedNotificationFilteringEntitlement = false

  private static func quietedForOwnSiblingDevice(
    wake: PushWakePayload,
    preview: NotificationPreview,
    hasFilteringEntitlement: Bool
  ) -> UNNotificationContent {
    if hasFilteringEntitlement {
      return UNNotificationContent()
    }
    let content = UNMutableNotificationContent()
    content.title = preview.groupTitle ?? "Catbird"
    content.subtitle = ""
    content.body = "Synced message from your other device"
    content.sound = nil
    content.badge = nil
    content.interruptionLevel = .passive
    content.relevanceScore = 0
    content.attachments = []
    content.threadIdentifier = "catbird-own-device-suppressed"
    content.categoryIdentifier = ""
    content.targetContentIdentifier = nil
    #if os(iOS)
    content.launchImageName = ""
    #endif
    content.userInfo = [
      "suppressedForOwnSiblingDevice": true,
      "silentDropRequiresManagedFilteringEntitlement": true,
      "convo_id": preview.conversationId,
      "message_id": preview.messageId,
      "recipient_account": wake.recipientAccountHash,
    ]
    return content
  }

  /// The sender's name from the profiles the app has already cached on this device, for a
  /// decrypted preview that carries none. A push names no sender, so the engine learns who
  /// wrote the message only by decrypting it and cannot have looked the name up beforehand.
  /// Local read only: the extension never asks the network who sent an encrypted message.
  static func cachedSenderName(for preview: NotificationPreview) async -> String? {
    guard !preview.fallbackGeneric, Self.nonEmpty(preview.senderDisplayName) == nil else { return nil }
    let senderDID = canonicalRootDID(preview.senderDid)
    guard !senderDID.isEmpty,
          let profile = await ProfileCacheDatabase.shared.read(did: senderDID)
    else { return nil }
    return Self.nonEmpty(profile.displayName) ?? Self.nonEmpty(profile.handle).map { "@\($0)" }
  }

  /// The name shown for a decrypted message: the engine's, else the cached profile's, else the app's.
  static func senderName(preview: NotificationPreview, cachedSenderName: String?) -> String {
    Self.nonEmpty(preview.senderDisplayName) ?? Self.nonEmpty(cachedSenderName) ?? "Catbird"
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  /// Whether the preview is shown as a message from another person: decrypted, and not one of
  /// the account's own devices.
  static func presentsAsIncomingMessage(
    preview: NotificationPreview,
    wake: PushWakePayload,
    recipientAccountDID: String?
  ) -> Bool {
    !preview.fallbackGeneric
      && !isOwnSiblingSender(preview: preview, wake: wake, recipientAccountDID: recipientAccountDID)
  }

  /// The intent iOS uses to present the notification as a message from `senderName`. It carries
  /// who and which conversation, never the message text: the text stays in the notification body.
  static func incomingMessageIntent(preview: NotificationPreview, senderName: String) -> INSendMessageIntent {
    let senderId = preview.senderDid.isEmpty ? preview.conversationId : canonicalRootDID(preview.senderDid)
    let sender = INPerson(
      personHandle: INPersonHandle(value: senderId, type: .unknown),
      nameComponents: nil,
      displayName: senderName,
      image: nil,
      contactIdentifier: nil,
      customIdentifier: senderId
    )
    return INSendMessageIntent(
      recipients: nil,
      outgoingMessageType: .outgoingMessageText,
      content: nil,
      speakableGroupName: preview.groupTitle.map(INSpeakableString.init(spokenPhrase:)),
      conversationIdentifier: preview.conversationId,
      serviceName: "Catbird",
      sender: sender,
      attachments: nil
    )
  }

  /// "New encrypted message", with what the app needs to open the conversation and nothing
  /// from the message itself.
  static func genericChatNotification(
    base: UNMutableNotificationContent,
    wake: PushWakePayload
  ) -> UNNotificationContent {
    Self.applyFallback(to: base, wake: wake)
    var info = base.userInfo
    info["type"] = wake.kind.contains("request") ? "mls_message_request" : "mls_message"
    info["protocol_version"] = "2"
    info["convo_id"] = wake.conversationId
    info["recipient_account"] = wake.recipientAccountHash
    base.userInfo = info
    return base
  }

  static func buildCommunicationNotification(
    base: UNMutableNotificationContent,
    preview: NotificationPreview,
    wake: PushWakePayload,
    recipientAccountDID: String? = nil,
    cachedSenderName: String? = nil,
    hasFilteringEntitlement: Bool = NotificationService.hasManagedNotificationFilteringEntitlement
  ) -> UNNotificationContent {
    // The engine returns text only for a message it decrypted and whose sender leaf matches a
    // DID-rooted device key. `receiptVerified` is false when that message came from the wake
    // alone, with no sequencer receipt fetched: it is shown, and the app syncs it for real on
    // open. Anything the engine could not decrypt arrives as a generic fallback.
    guard !preview.fallbackGeneric else {
      return Self.genericChatNotification(base: base, wake: wake)
    }

    if Self.isOwnSiblingSender(preview: preview, wake: wake, recipientAccountDID: recipientAccountDID) {
      return Self.quietedForOwnSiblingDevice(
        wake: wake,
        preview: preview,
        hasFilteringEntitlement: hasFilteringEntitlement
      )
    }

    let senderName = Self.senderName(preview: preview, cachedSenderName: cachedSenderName)
    base.title = preview.groupTitle ?? senderName
    // In a named group the title is the group, so the sender goes on the second line.
    if preview.groupTitle != nil, senderName != "Catbird" {
      base.subtitle = senderName
    }
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

    let intent = Self.incomingMessageIntent(preview: preview, senderName: senderName)
    return (try? base.updating(from: intent)) ?? base
  }
}
