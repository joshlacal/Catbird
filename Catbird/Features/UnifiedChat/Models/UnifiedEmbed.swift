import Foundation

// MARK: - UnifiedEmbed

/// Unified embed type for both Bluesky and MLS chat messages
enum UnifiedEmbed: Hashable, Sendable {
  case blueskyRecord(recordData: BlueskyRecordEmbedData)
  case link(LinkEmbedData)
  case gif(GIFEmbedData)
  case post(PostEmbedData)
  case tile(TileEmbedData)
  case image(ImageEmbedData)
  case audio(AudioEmbedData)
  case groupInvite(GroupInviteEmbedData)
}

// MARK: - GroupInviteEmbedData

/// Join-link invite preview from `chat.bsky.embed.joinLink#view` (3-way open union).
/// Disabled, invalid, and unknown union members all collapse to `.unavailable` —
/// the schemas are unstable upstream, so an unknown `$type` must never render as a valid invite.
enum GroupInviteEmbedData: Hashable, Sendable {
  case preview(name: String, memberCount: Int, memberLimit: Int, code: String)
  case unavailable(code: String?)
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

// MARK: - ImageEmbedData

struct ImageEmbedData: Hashable, Sendable {
  let blobId: String
  let key: Data
  let iv: Data
  let sha256: String
  let contentType: String
  let size: Int
  let width: Int
  let height: Int
  let altText: String?
  let blurhash: String?
}

// MARK: - AudioEmbedData

struct AudioEmbedData: Hashable, Sendable {
  let blobId: String
  let key: Data
  let iv: Data
  let sha256: String
  let contentType: String
  let size: UInt64
  let durationMs: UInt64
  let waveform: [Float]
  let transcript: String?
}
