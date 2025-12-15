import Foundation

// MARK: - UnifiedEmbed

/// Unified embed type for both Bluesky and MLS chat messages
enum UnifiedEmbed: Hashable, Sendable {
  case blueskyRecord(recordData: BlueskyRecordEmbedData)
  case link(LinkEmbedData)
  case gif(GIFEmbedData)
  case post(PostEmbedData)
}

// MARK: - BlueskyRecordEmbedData

struct BlueskyRecordEmbedData: Hashable, Sendable {
  let uri: String
  let cid: String
}

// MARK: - LinkEmbedData

struct LinkEmbedData: Hashable, Sendable {
  let url: URL
  let title: String?
  let description: String?
  let thumbnailURL: URL?
}

// MARK: - GIFEmbedData

struct GIFEmbedData: Hashable, Sendable {
  let url: URL
  let previewURL: URL?
  let width: Int?
  let height: Int?
}

// MARK: - PostEmbedData

struct PostEmbedData: Hashable, Sendable {
  let uri: String
  let cid: String
  let authorDID: String
  let authorHandle: String?
  let text: String?
}
