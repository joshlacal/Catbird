import Foundation

// Mirror of the payload encoded by the share extension (see ShareViewController)
struct SharedIncomingPayload: Codable {
  let text: String?
  let urls: [String]
  let imageURLs: [String]?
  let images: [Data]? // legacy
  let videoURLs: [String]
}

enum IncomingSharedDraftHandler {
  static func importIfAvailable() {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared") ?? .standard
    guard let data = defaults.data(forKey: "incoming_shared_draft") else { return }
    defer {
      defaults.removeObject(forKey: "incoming_shared_draft")
      defaults.synchronize()
    }
    // First, try decoding a full draft
    let decoder = JSONDecoder()
    if let draft = try? decoder.decode(PostComposerDraft.self, from: data) {
      AppState.shared.composerDraftManager.storeDraft(draft)
      return
    }
    // Next, try a simple shared payload (from extension)
    if let payload = try? decoder.decode(SharedIncomingPayload.self, from: data) {
      let urls: [URL] = payload.urls.compactMap { URL(string: $0) }
      let videoURLs: [URL] = payload.videoURLs.compactMap { URL(string: $0) }
      let imageURLs: [URL] = (payload.imageURLs ?? []).compactMap { URL(string: $0) }
      let draft = SharedDraftImporter.makeDraft(text: payload.text, urls: urls, imageURLs: imageURLs, imagesData: payload.images, videoURLs: videoURLs)
      AppState.shared.composerDraftManager.storeDraft(draft)
      return
    }
  }
}
