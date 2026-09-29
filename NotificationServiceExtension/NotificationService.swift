import CryptoKit
import Foundation
import Petrel
import Security
import UserNotifications
import os.log

/// Notification Service Extension for Catbird.
///
/// Responsibilities:
/// - Bluesky DM pushes (`type == "chat_message"`, sent by the nest gateway): resolve the
///   sender's display name + avatar (shared profile cache first, then the Bluesky API) and
///   set thread/category/tap-routing info.
/// - Pushes for features this build does not ship (encrypted MLS chat, key-package
///   replenishment requests, Circles activity): the app cannot act on them, and without the
///   `com.apple.developer.usernotifications.filtering` entitlement the extension cannot drop
///   a notification, so their content is replaced with a neutral generic alert that carries
///   no payload data.
/// - Everything else (mentions, likes, reposts, follows, replies, quotes, ...) is delivered
///   exactly as the server sent it.
class NotificationService: UNNotificationServiceExtension {

  /// Guards `contentHandler`, which is consumed from either the processing task or
  /// `serviceExtensionTimeWillExpire` (different threads).
  private let handlerLock = NSLock()
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?
  private var processingTask: Task<Void, Never>?

  private let logger = Logger(
    subsystem: "blue.catbird.notification-service", category: "NotificationService")

  /// App Group suite name for shared storage
  private static let appGroupSuite = "group.blue.catbird.shared"

  /// Push `type` values for features that are not part of this build.
  private static let unsupportedPushTypes: Set<String> = [
    "mls_message",
    "mls_message_request",
    "key_package_replenish_request",
  ]

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler

    guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
      logger.error("[NSE] Failed to create mutable content copy")
      contentHandler(request.content)
      return
    }
    bestAttemptContent = content

    let userInfo = request.content.userInfo
    let pushType = userInfo["type"] as? String
    let pushKind = userInfo["kind"] as? String

    if let pushType, Self.unsupportedPushTypes.contains(pushType) {
      logger.info("[NSE] Unsupported push type \(pushType, privacy: .public) - neutralizing content")
      deliver(Self.neutralized(content))
      return
    }

    if pushKind == "circle_activity" {
      logger.info("[NSE] Unsupported circle_activity push - neutralizing content")
      deliver(Self.neutralized(content))
      return
    }

    guard pushType == "chat_message" else {
      logger.debug("[NSE] Delivering push as-is (type=\(pushType ?? "nil", privacy: .public))")
      deliver(content)
      return
    }

    processingTask = Task { [weak self] in
      guard let self else { return }
      await self.enrichChatMessage(content: content, userInfo: userInfo)
      guard !Task.isCancelled else { return }
      self.deliver(content)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    logger.warning("[NSE] Time will expire - delivering best attempt content")
    processingTask?.cancel()
    if let bestAttemptContent {
      deliver(bestAttemptContent)
    }
  }

  // MARK: - Delivery

  /// Calls the content handler exactly once.
  private func deliver(_ content: UNNotificationContent) {
    handlerLock.lock()
    let handler = contentHandler
    contentHandler = nil
    handlerLock.unlock()
    handler?(content)
  }

  /// Replaces all displayable content with a generic alert. Used for pushes from features
  /// this build does not include, so no server-supplied text or identifiers are shown.
  private static func neutralized(_ original: UNMutableNotificationContent)
    -> UNMutableNotificationContent
  {
    let content = UNMutableNotificationContent()
    content.title = "Catbird"
    content.body = "New activity"
    content.sound = original.sound
    content.threadIdentifier = "catbird-unsupported"
    return content
  }

  // MARK: - Bluesky Chat Message Push Handling

  /// Enriches a `chat_message` push with the sender's profile. The message text is in the
  /// push payload (Bluesky DMs are not end-to-end encrypted).
  private func enrichChatMessage(
    content: UNMutableNotificationContent,
    userInfo: [AnyHashable: Any]
  ) async {
    let senderDid = userInfo["senderDid"] as? String
    let convoId = userInfo["convoId"] as? String
    let messageText = userInfo["messageText"] as? String
    let recipientDid = resolveChatRecipientDID(from: userInfo)

    var senderName: String?
    var senderAvatarURL: String?

    if let senderDid {
      // Shared profile cache first (written by the main app's ChatManager)
      if let cached = await ProfileCacheDatabase.shared.read(did: senderDid) {
        senderName = cached.displayName ?? cached.handle
        senderAvatarURL = cached.avatarURL
      }

      // Fallback: fetch from the Bluesky API via a standalone client
      if senderName == nil,
        let clientDid = recipientDid ?? firstKnownAccountDID(),
        let profile = await fetchProfile(senderDid: senderDid, asAccount: clientDid)
      {
        senderName = profile.displayName ?? profile.handle
        senderAvatarURL = profile.avatarURL
      }
    }

    if let senderName {
      content.title = senderName
    } else if let senderDid, let shortDid = formatShortDID(senderDid) {
      content.title = shortDid
    } else if content.title.isEmpty {
      content.title = "New Message"
    }

    if let messageText, !messageText.isEmpty {
      content.body = messageText
    } else if content.body.isEmpty {
      content.body = "Sent you a message"
    }

    if let convoId {
      content.threadIdentifier = "chat:\(convoId)"
    }

    // Tap navigation info. recipientDid lets the main app switch to the target account
    // before navigating; omitted when unresolvable so the existing tap behavior applies.
    var updatedUserInfo = content.userInfo
    updatedUserInfo["type"] = "chat_message"
    if let convoId { updatedUserInfo["convoId"] = convoId }
    if let senderDid { updatedUserInfo["senderDid"] = senderDid }
    if let recipientDid { updatedUserInfo["recipientDid"] = recipientDid }
    content.userInfo = updatedUserInfo

    content.categoryIdentifier = "CHAT_MESSAGE"

    if let senderAvatarURL, let avatarURL = URL(string: senderAvatarURL) {
      await attachProfilePhoto(to: content, from: avatarURL)
    }
  }

  // MARK: - Account Resolution

  /// Resolves the target account DID for a `chat_message` push. Only definitive sources are
  /// honored — explicit payload fields or the `recipient_account` hash — never a guessed
  /// local account, since a wrong DID would switch the user to the wrong account on tap.
  private func resolveChatRecipientDID(from userInfo: [AnyHashable: Any]) -> String? {
    if let did = userInfo["recipientDid"] as? String { return did }
    if let did = userInfo["recipient_did"] as? String { return did }
    if let hash = userInfo["recipient_account"] as? String {
      return resolveRecipientDID(fromHash: hash)
    }
    return nil
  }

  /// Account DIDs published by the main app (`AppStateManager`) to App Group defaults.
  private func knownAccountDIDs() -> [String] {
    UserDefaults(suiteName: Self.appGroupSuite)?.stringArray(forKey: "knownAccountDIDs") ?? []
  }

  private func firstKnownAccountDID() -> String? {
    knownAccountDIDs().first
  }

  /// Resolves a `recipient_account` value (lowercase hex SHA-256 of the recipient DID) to a
  /// locally signed-in account by hashing each known account DID.
  private func resolveRecipientDID(fromHash hash: String) -> String? {
    let normalizedHash = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalizedHash.count == 64,
      normalizedHash.allSatisfy({ $0.isHexDigit })
    else {
      logger.warning("[NSE] Invalid recipient_account hash format")
      return nil
    }

    for did in knownAccountDIDs() {
      let candidates = [did, did.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
      for candidate in candidates where Self.sha256Hex(candidate) == normalizedHash {
        return did
      }
    }
    logger.info("[NSE] No local account matched recipient_account hash")
    return nil
  }

  private static func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Profile Lookup

  /// Fetches a Bluesky profile via a standalone ATProtoClient using the shared keychain session.
  private func fetchProfile(senderDid: String, asAccount accountDid: String) async
    -> (displayName: String?, handle: String, avatarURL: String?)?
  {
    guard let client = await createStandaloneClient(for: accountDid) else { return nil }
    do {
      let params = AppBskyActorGetProfile.Parameters(actor: try ATIdentifier(string: senderDid))
      let (_, profile) = try await client.app.bsky.actor.getProfile(input: params)
      guard let profile else { return nil }
      return (
        displayName: profile.displayName,
        handle: profile.handle.description,
        avatarURL: profile.avatar?.uriString()
      )
    } catch {
      logger.debug("[NSE] Profile fetch failed: \(error.localizedDescription)")
      return nil
    }
  }

  private func createStandaloneClient(for userDid: String) async -> ATProtoClient? {
    #if targetEnvironment(simulator)
      let accessGroup: String? = nil
    #else
      let accessGroup: String? = Self.sharedKeychainAccessGroup()
    #endif

    let oauthConfig = OAuthConfiguration(
      clientId: "https://catbird.blue/oauth-client-metadata.json",
      redirectUri: "https://catbird.blue/oauth/callback",
      scope: "atproto transition:generic transition:chat.bsky"
    )

    do {
      let client = try await ATProtoClient(
        oauthConfig: oauthConfig,
        namespace: "blue.catbird",
        authMode: .gateway,
        gatewayURL: URL(string: "https://api.catbird.blue")!,
        userAgent: "Catbird/1.0",
        bskyAppViewDID: "did:web:api.bsky.app#bsky_appview",
        bskyChatDID: "did:web:api.bsky.chat#bsky_chat",
        accessGroup: accessGroup
      )
      try await client.switchToAccount(did: userDid)
      return client
    } catch {
      logger.error("[NSE] Failed to create standalone client: \(error.localizedDescription)")
      return nil
    }
  }

  /// Resolves the full shared keychain access group (`<TeamID>.blue.catbird.shared`).
  /// iOS has no SecTask API, so the Team ID prefix is inferred from the default access
  /// group of a throwaway probe item.
  private static func sharedKeychainAccessGroup() -> String? {
    let probeService = "blue.catbird.nse.accessGroupProbe"
    let probeAccount = UUID().uuidString
    let baseQuery: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: probeService,
      kSecAttrAccount: probeAccount,
    ]
    var addQuery = baseQuery
    addQuery[kSecValueData] = Data([0])
    addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    _ = SecItemAdd(addQuery as CFDictionary, nil)
    defer { SecItemDelete(baseQuery as CFDictionary) }

    var matchQuery = baseQuery
    matchQuery[kSecReturnAttributes] = true
    matchQuery[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(matchQuery as CFDictionary, &item) == errSecSuccess,
      let attrs = item as? [CFString: Any],
      let defaultGroup = attrs[kSecAttrAccessGroup] as? String,
      let dot = defaultGroup.firstIndex(of: ".")
    else {
      return nil
    }
    return "\(defaultGroup[..<dot]).blue.catbird.shared"
  }

  // MARK: - Attachments

  /// Downloads and attaches the sender's profile photo to the notification.
  private func attachProfilePhoto(to content: UNMutableNotificationContent, from url: URL) async {
    do {
      let (data, response) = try await URLSession.shared.data(from: url)
      guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        logger.warning("[NSE] Profile photo download failed - invalid response")
        return
      }

      let mimeType = httpResponse.mimeType ?? "image/jpeg"
      let fileExtension: String
      switch mimeType {
      case "image/png": fileExtension = "png"
      case "image/gif": fileExtension = "gif"
      default: fileExtension = "jpg"
      }

      let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
      try data.write(to: fileURL)

      let attachment = try UNNotificationAttachment(
        identifier: "avatar",
        url: fileURL,
        options: [UNNotificationAttachmentOptionsTypeHintKey: mimeType]
      )
      content.attachments = [attachment]
    } catch {
      logger.warning("[NSE] Failed to attach profile photo: \(error.localizedDescription)")
    }
  }

  /// Formats a DID for display when no profile info is available,
  /// e.g. "did:plc:abc123xyz456" -> "abc123xy..."
  private func formatShortDID(_ did: String) -> String? {
    guard let lastPart = did.split(separator: ":").last else { return nil }
    let identifier = String(lastPart.prefix(8))
    return identifier.isEmpty ? nil : "\(identifier)..."
  }
}
