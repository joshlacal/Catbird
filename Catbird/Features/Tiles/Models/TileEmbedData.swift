import Foundation

// MARK: - TileEmbedData

/// Embed data for rendering a tile in feed or chat contexts
struct TileEmbedData: Hashable, Sendable {
  /// AT Protocol URI for the tile record
  let uri: String
  /// CID of the tile record
  let recordCID: String
  /// The tile's content CID (from the record)
  let tileCID: String
  /// Tile name
  let name: String
  /// Tile description
  let tileDescription: String?
  /// URL to the first icon resource (resolved)
  let iconURL: URL?
  /// URL to the first screenshot resource (resolved for card banner)
  let screenshotURL: URL?
  /// Requested sizing
  let sizing: TileSizing?
  /// The full manifest (needed for live rendering)
  let manifest: TileManifest?
}
