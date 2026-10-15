import Foundation
import Petrel

// MARK: - Labels and mapping

extension ChatRecordEmbedStore {
  /// The labeler DIDs (sorted) a record must be hydrated under for `policyLabelerDIDs`, or nil while
  /// the applied header names a different set. The policy trusts exactly the labelers the header
  /// names (both capped at 20 like the header), so every label a record can carry is one the policy acts
  /// on: a header that lacks a trusted labeler would miss its labels, and one that names a labeler the
  /// policy does not trust yet would bring labels the policy ignores.
  nonisolated static func coveringLabelers(policyLabelerDIDs: [String], applied: [String]?) -> [String]? {
    guard let applied else { return nil }
    let required = PreferencesManager.acceptLabelers(subscribedDIDs: policyLabelerDIDs).map(\.did)
    guard Set(required) == Set(applied) else { return nil }
    return applied.sorted()
  }

  /// Whether a card must stay covered because the record, or a record it quotes, carries a label from
  /// a labeler the policy trusts that the policy cannot resolve while the labelers' definitions are
  /// still loading. Once the load settles, a label that still has no definition is ignored, as the
  /// moderation engine does everywhere.
  nonisolated static func awaitsLabelDefinitions(
    _ record: Record, policy: ModerationPolicy, definitionsLoading: Bool
  ) -> Bool {
    guard definitionsLoading else { return false }
    let trusted = Set(policy.prefs.labelers.map(\.did))
    let now = Date()
    return labels(in: record, depth: 2).contains { label in
      label.neg != true && (label.exp.map { $0.date > now } ?? true)
        && trusted.contains(label.src.didString()) && policy.definition(for: label) == nil
    }
  }

  private nonisolated static func labels(in record: Record, depth: Int) -> [ComAtprotoLabelDefs.Label] {
    guard depth > 0, case .appBskyEmbedRecordViewRecord(let post) = record else { return [] }
    var labels = (post.labels ?? []) + (post.author.labels ?? [])
    for embed in post.embeds ?? [] {
      switch embed {
      case .appBskyEmbedRecordView(let view):
        labels += Self.labels(in: view.record, depth: depth - 1)
      case .appBskyEmbedRecordWithMediaView(let view):
        labels += Self.labels(in: view.record.record, depth: depth - 1)
      default:
        break
      }
    }
    return labels
  }

  /// The post's and author's active labels as "src|uri|val".
  nonisolated static func labelSignature(_ record: Record) -> Set<String> {
    guard case .appBskyEmbedRecordViewRecord(let post) = record else { return [] }
    let labels = (post.labels ?? []) + (post.author.labels ?? [])
    return Set(labels.filter { $0.neg != true }.map { "\($0.src.didString())|\($0.uri.uriString())|\($0.val)" })
  }

  // MARK: Mapping

  nonisolated static func viewRecord(from post: AppBskyFeedDefs.PostView) -> Record {
    let embeds = post.embed.map(mapEmbed)
    return .appBskyEmbedRecordViewRecord(AppBskyEmbedRecord.ViewRecord(
      uri: post.uri, cid: post.cid, author: post.author, value: post.record,
      labels: post.labels, replyCount: post.replyCount, repostCount: post.repostCount,
      likeCount: post.likeCount, quoteCount: post.quoteCount,
      embeds: embeds?.isEmpty == false ? embeds : nil, indexedAt: post.indexedAt
    ))
  }

  private nonisolated static func mapEmbed(
    _ embed: AppBskyFeedDefs.PostViewEmbedUnion
  ) -> [AppBskyEmbedRecord.ViewRecordEmbedsUnion] {
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

  /// getPosts through `client`, which sends the account's accept-labelers header.
  nonisolated static func postsLoader(client: ATProtoClient) -> PostsLoader {
    { uris in
      let (status, output) = try await client.app.bsky.feed.getPosts(input: .init(uris: uris))
      guard status == 200, let output else { throw URLError(.badServerResponse) }
      return output.posts
    }
  }
}
