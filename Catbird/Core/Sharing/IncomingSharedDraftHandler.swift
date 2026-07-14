import Foundation
import OSLog


// Mirror of the payload encoded by the share extension (see ShareViewController)
struct SharedIncomingPayload: Codable {
  let text: String?
  let urls: [String]
  let imageURLs: [String]?
  let images: [Data]? // legacy
  let videoURLs: [String]
}

enum IncomingSharedDraftHandler {
    private static let logger = Logger(subsystem: "blue.catbird", category: "IncomingSharedDraftHandler")

  @MainActor
  static func importIfAvailable() {
    logger.info("🔍 Checking for incoming shared draft")

    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared") ?? .standard
    guard let data = defaults.data(forKey: "incoming_shared_draft") else {
      logger.debug("  No incoming shared draft found")
      return
    }

    // Keep the payload until a signed-in AppState can actually accept it.
    // This handler also runs during launch, before lifecycle setup completes.
    guard let appState = AppStateManager.shared.lifecycle.appState else {
      logger.info("  Deferring incoming shared draft until AppState is available")
      return
    }

    logger.info("📥 Found incoming shared draft - Size: \(data.count) bytes")

    defer {
      defaults.removeObject(forKey: "incoming_shared_draft")
      defaults.synchronize()
      logger.debug("  Cleared incoming_shared_draft from UserDefaults")
    }
    // First, try decoding a full draft
    let decoder = JSONDecoder()

    logger.debug("  Attempting to decode as PostComposerDraft")
    if let draft = try? decoder.decode(PostComposerDraft.self, from: data) {
      logger.info("✅ Successfully decoded as PostComposerDraft - Post text length: \(draft.postText.count), Media items: \(draft.mediaItems.count)")
      appState.composerDraftManager.storeDraft(draft)
      logger.debug("  Stored draft in ComposerDraftManager")
      return
    }

    // Next, try a simple shared payload (from extension)
    logger.debug("  Attempting to decode as SharedIncomingPayload")
    if let payload = try? decoder.decode(SharedIncomingPayload.self, from: data) {
      logger.info("✅ Successfully decoded as SharedIncomingPayload")
      logger.debug("  Text: \(payload.text?.prefix(50) ?? "nil"), URLs: \(payload.urls.count), Images: \(payload.imageURLs?.count ?? payload.images?.count ?? 0), Videos: \(payload.videoURLs.count)")

      let urls: [URL] = payload.urls.compactMap { URL(string: $0) }
      let videoURLs: [URL] = payload.videoURLs.compactMap { URL(string: $0) }
      let imageURLs: [URL] = (payload.imageURLs ?? []).compactMap { URL(string: $0) }

      logger.debug("  Parsed URLs - General: \(urls.count), Videos: \(videoURLs.count), Images: \(imageURLs.count)")

      let draft = SharedDraftImporter.makeDraft(text: payload.text, urls: urls, imageURLs: imageURLs, imagesData: payload.images, videoURLs: videoURLs)
      appState.composerDraftManager.storeDraft(draft)
      logger.info("✅ Created and stored draft from shared payload")
      return
    }

    logger.error("❌ Failed to decode shared draft data as either PostComposerDraft or SharedIncomingPayload")
  }
}
