import Foundation
import Petrel

/// The shared post no longer exists or isn't visible to this account
/// (deleted, or its author blocked the viewer). Retrying won't help.
struct ChatRecordEmbedUnavailableError: Error {}

/// Session-scoped metadata, shared by UIKit prefetch and visible SwiftUI cells.
/// No guessed height is stored: a warm record renders its real text and media
/// aspect ratios on the first sizing pass, at the current width and text size.
@MainActor
final class ChatRecordEmbedStore {
  static let shared = ChatRecordEmbedStore()
  typealias Record = AppBskyEmbedRecord.ViewRecordUnion

  private struct Key: Hashable, Sendable {
    let account: String
    let state: ObjectIdentifier
    let client: ObjectIdentifier
    let uri: String
  }

  private var records: [Key: Record] = [:]
  private let requests = ChatEmbedRequestPool<Key, Record>()

  private func isActive(_ state: AppState) -> Bool {
    let lifecycle = AppStateManager.shared.lifecycle
    return lifecycle.appState === state && lifecycle.userDID == state.userDID
      && !state.isTransitioningAccounts
  }

  func cachedRecord(uri: String, appState: AppState) -> Record? {
    guard isActive(appState), let client = appState.atProtoClient else { return nil }
    return records[Key(account: appState.userDID, state: ObjectIdentifier(appState),
      client: ObjectIdentifier(client), uri: uri)]
  }

  func load(uri: String, appState: AppState) async throws -> Record {
    try Task.checkCancellation()
    guard isActive(appState), let client = appState.atProtoClient else { throw CancellationError() }
    let key = Key(account: appState.userDID, state: ObjectIdentifier(appState),
      client: ObjectIdentifier(client), uri: uri)
    if let cached = records[key] { return cached }
    guard let postURI = try? ATProtocolURI(uriString: uri) else { throw URLError(.badURL) }

    let record = try await requests.value(for: key) {
      let (status, response) = try await client.app.bsky.feed.getPosts(input: .init(uris: [postURI]))
      try Task.checkCancellation()
      guard status == 200 else { throw URLError(.badServerResponse) }
      guard let post = response?.posts.first else { throw ChatRecordEmbedUnavailableError() }
      let embeds = post.embed.map(Self.mapEmbed)
      return .appBskyEmbedRecordViewRecord(AppBskyEmbedRecord.ViewRecord(
        uri: post.uri, cid: post.cid, author: post.author, value: post.record,
        labels: post.labels, replyCount: post.replyCount, repostCount: post.repostCount,
        likeCount: post.likeCount, quoteCount: post.quoteCount,
        embeds: embeds?.isEmpty == false ? embeds : nil, indexedAt: post.indexedAt
      ))
    }
    try Task.checkCancellation()
    guard isActive(appState), appState.atProtoClient === client else { throw CancellationError() }
    // Evict one entry rather than collapsing all warm geometry at capacity.
    if records[key] == nil, records.count >= 256, let evictedKey = records.keys.first {
      records.removeValue(forKey: evictedKey)
    }
    records[key] = record
    return record
  }

  private static func mapEmbed(_ embed: AppBskyFeedDefs.PostViewEmbedUnion) -> [AppBskyEmbedRecord.ViewRecordEmbedsUnion] {
    switch embed {
    case .appBskyEmbedImagesView(let value): return [.appBskyEmbedImagesView(value)]
    case .appBskyEmbedGalleryView(let value): return [.appBskyEmbedGalleryView(value)]
    case .appBskyEmbedExternalView(let value): return [.appBskyEmbedExternalView(value)]
    case .appBskyEmbedRecordView(let value): return [.appBskyEmbedRecordView(value)]
    case .appBskyEmbedRecordWithMediaView(let value): return [.appBskyEmbedRecordWithMediaView(value)]
    case .appBskyEmbedVideoView(let value): return [.appBskyEmbedVideoView(value)]
    case .unexpected: return []
    }
  }
}

extension UnifiedEmbed {
  var recordURI: String? {
    switch self {
    case .blueskyRecord(let record): return record.uri
    case .post(let post): return post.uri
    default: return nil
    }
  }
}
