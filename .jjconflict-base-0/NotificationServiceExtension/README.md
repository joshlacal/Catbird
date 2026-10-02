# NotificationServiceExtension

Enriches incoming push notifications before iOS displays them.

- `type == "chat_message"` (Bluesky DMs, sent by the nest gateway): resolves the sender's
  display name and avatar from the shared profile cache (`ProfileCacheDatabase`, GRDB, App
  Group `group.blue.catbird.shared`), falling back to `app.bsky.actor.getProfile` through a
  standalone `ATProtoClient` that reads the shared keychain session. Sets the thread id,
  `CHAT_MESSAGE` category, and tap-routing keys (`convoId`, `senderDid`, `recipientDid`).
- `type` in `mls_message`, `mls_message_request`, `key_package_replenish_request`, or
  `kind == "circle_activity"`: these features are not part of this build. The extension has
  no `com.apple.developer.usernotifications.filtering` entitlement, so it cannot drop them;
  it replaces the content with a generic "Catbird / New activity" alert carrying no payload
  data.
- Everything else is delivered unchanged.

`recipient_account` (SHA-256 hex of the recipient DID) is resolved by hashing the DIDs the
main app publishes under `knownAccountDIDs` in App Group defaults.
