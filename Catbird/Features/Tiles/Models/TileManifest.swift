import Foundation

// MARK: - TileManifest

/// Represents a DASL Web Tile manifest (MASL metadata)
/// See: https://dasl.ing/tiles.html
struct TileManifest: Codable, Hashable, Sendable {
  /// The name for the tile (app name or title)
  let name: String

  /// Short overview of the content
  let description: String?

  /// Tags categorizing the tile
  let categories: [String]?

  /// Background color for the tile
  let backgroundColor: String?

  /// Icons for the tile
  let icons: [TileIcon]?

  /// Screenshots for card/banner images
  let screenshots: [TileScreenshot]?

  /// Requested sizing for the content
  let sizing: TileSizing?

  /// Resource map: path → TileResource
  let resources: [String: TileResource]

  /// Short name fallback
  let shortName: String?

  /// Theme color
  let themeColor: String?

  /// CID of previous version of this tile
  let prev: String?

  enum CodingKeys: String, CodingKey {
    case name, description, categories, icons, screenshots, sizing, resources
    case backgroundColor = "background_color"
    case shortName = "short_name"
    case themeColor = "theme_color"
    case prev
  }
}

// MARK: - TileIcon

struct TileIcon: Codable, Hashable, Sendable {
  /// Path to icon resource (must be in resources map)
  let src: String
  /// Icon sizes (e.g., "192x192")
  let sizes: String?
  /// Icon purpose (e.g., "maskable")
  let purpose: String?
}

// MARK: - TileScreenshot

struct TileScreenshot: Codable, Hashable, Sendable {
  /// Path to screenshot resource
  let src: String
  /// Screenshot dimensions
  let sizes: String?
  /// Accessibility label
  let label: String?
}

// MARK: - TileSizing

struct TileSizing: Codable, Hashable, Sendable {
  let width: Int
  let height: Int
}

// MARK: - TileResource

/// A single resource in a tile's resource map
struct TileResource: Codable, Hashable, Sendable {
  /// The blob source (contains CID reference)
  let src: TileResourceSource
  /// HTTP content-type for this resource
  let contentType: String

  enum CodingKeys: String, CodingKey {
    case src
    case contentType = "content-type"
  }
}

// MARK: - TileResourceSource

/// Source reference for a tile resource (AT Protocol blob)
struct TileResourceSource: Codable, Hashable, Sendable {
  /// Blob type identifier
  let type: String?
  /// CID link reference
  let ref: TileResourceRef?
  /// Size in bytes
  let size: Int?
  /// MIME type (often application/octet-stream for PDS compatibility)
  let mimeType: String?

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case ref
    case size, mimeType
  }
}

// MARK: - TileResourceRef

struct TileResourceRef: Codable, Hashable, Sendable {
  /// The CID link
  let link: String

  enum CodingKeys: String, CodingKey {
    case link = "$link"
  }
}
