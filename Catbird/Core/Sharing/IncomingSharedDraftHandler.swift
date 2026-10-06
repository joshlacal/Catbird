import Foundation
import OSLog

// Mirror of the payload encoded by the share extension (see ShareViewController).
struct SharedIncomingPayload: Codable {
  let text: String?
  let urls: [String]
  let imageURLs: [String]?
  let images: [Data]? // legacy
  let videoURLs: [String]
}

@MainActor
enum IncomingSharedDraftHandler {
  private static let logger = Logger(subsystem: "blue.catbird", category: "IncomingSharedDraftHandler")
  private static let payloadKey = "incoming_shared_draft"

  /// Repeated scene activation keeps the first receiving window and request ID.
  /// The coordinator deduplicates queued requests; after expiry the same payload
  /// can be retried without removing the durable source bytes.
  private struct PendingImport {
    let data: Data
    let request: SceneRouteRequest
    let stagedAt: TimeInterval
  }
  private static var pendingImport: PendingImport?

  static func importIfAvailable() {
    guard let defaults = UserDefaults(suiteName: "group.blue.catbird.shared"),
          let accountDID = AppStateManager.shared.lifecycle.appState?.userDID else { return }
    let coordinator = SceneRouteCoordinator.shared
    importIfAvailable(defaults: defaults, accountDID: accountDID,
      coordinator: coordinator, preferredSceneID: coordinator.preferredSceneIDForExternalEvent())
  }

  /// Kept injectable for offline routing and failure-retention tests.
  static func importIfAvailable(
    defaults: UserDefaults,
    accountDID: String,
    coordinator: SceneRouteCoordinator,
    preferredSceneID: UUID?,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    guard let data = defaults.data(forKey: payloadKey), let draft = decode(data) else { return }
    let staged: PendingImport
    if let existing = pendingImport, existing.data == data,
       existing.request.accountDID == accountDID,
       now - existing.stagedAt < SceneRouteCoordinator.pendingTTL {
      staged = existing
    } else {
      staged = PendingImport(data: data, request: SceneRouteRequest(
        accountDID: accountDID, command: .showTab(0, resetPath: false),
        preferredSceneID: preferredSceneID), stagedAt: now)
      pendingImport = staged
    }

    let result = coordinator.submit(staged.request) { context in
      // A newer import supersedes only the pending presentation. Its source
      // bytes must never be erased by an older queued callback.
      guard pendingImport?.request.id == staged.request.id,
            defaults.data(forKey: payloadKey) == staged.data,
            !context.isInvalidated, context.accountDID == staged.request.accountDID else { return false }
      do {
        let claim = try context.composerEditingSession.beginNew(draft: draft)
        guard !context.isInvalidated else { return false }
        context.postComposerRequest = ScenePostComposerRequest(editingClaim: claim)
        if defaults.data(forKey: payloadKey) == staged.data {
          defaults.removeObject(forKey: payloadKey)
        }
        if pendingImport?.request.id == staged.request.id { pendingImport = nil }
        return true
      } catch {
        // The scene session retains any replaced editor. Keep the incoming
        // payload too, so storage or lifecycle failure can be retried.
        logger.error("Unable to accept shared draft into the receiving scene")
        return false
      }
    }
    if case .dropped = result, pendingImport?.request.id == staged.request.id {
      // This presentation attempt has ended. The retained payload can be
      // retried by a later activation, which captures its new receiving scene.
      pendingImport = nil
    }
  }

  private static func decode(_ data: Data) -> PostComposerDraft? {
    let decoder = JSONDecoder()
    if let draft = try? decoder.decode(PostComposerDraft.self, from: data) { return draft }
    guard let payload = try? decoder.decode(SharedIncomingPayload.self, from: data) else {
      logger.error("Unable to decode incoming shared draft; preserving source payload")
      return nil
    }
    return SharedDraftImporter.makeDraft(
      text: payload.text,
      urls: payload.urls.compactMap(URL.init(string:)),
      imageURLs: (payload.imageURLs ?? []).compactMap(URL.init(string:)),
      imagesData: payload.images,
      videoURLs: payload.videoURLs.compactMap(URL.init(string:)))
  }
}
