import Foundation

// MARK: - TileRecord

/// An AT Protocol record containing a tile
/// Corresponds to ing.dasl.masl#main
struct TileRecord: Codable, Hashable, Sendable {
  /// The DRISL CID of the MASL for the tile
  let cid: String
  /// The MASL manifest content
  let tile: TileManifest
  /// Creation timestamp
  let createdAt: Date
}
