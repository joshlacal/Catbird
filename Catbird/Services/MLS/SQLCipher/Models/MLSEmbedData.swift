//
//  MLSEmbedData.swift
//  Catbird
//
//  MLS message embed data types
//

import Foundation

/// Rich embed data for MLS messages
public enum MLSEmbedData: Codable, Sendable, Hashable {
  case record(MLSRecordEmbed)
  case link(MLSLinkEmbed)
  case gif(MLSGIFEmbed)

  // MARK: - Codable

  enum CodingKeys: String, CodingKey {
    case type
    case data
  }

  enum EmbedType: String, Codable {
    case record
    case link
    case gif
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(EmbedType.self, forKey: .type)

    switch type {
    case .record:
      let record = try container.decode(MLSRecordEmbed.self, forKey: .data)
      self = .record(record)
    case .link:
      let link = try container.decode(MLSLinkEmbed.self, forKey: .data)
      self = .link(link)
    case .gif:
      let gif = try container.decode(MLSGIFEmbed.self, forKey: .data)
      self = .gif(gif)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    switch self {
    case .record(let record):
      try container.encode(EmbedType.record, forKey: .type)
      try container.encode(record, forKey: .data)
    case .link(let link):
      try container.encode(EmbedType.link, forKey: .type)
      try container.encode(link, forKey: .data)
    case .gif(let gif):
      try container.encode(EmbedType.gif, forKey: .type)
      try container.encode(gif, forKey: .data)
    }
  }
}

// MARK: - Bluesky Record Embed (Quote Post)

/// Bluesky record embed (quote post)
public struct MLSRecordEmbed: Codable, Sendable, Hashable {
  public let uri: String
  public let cid: String?
  public let authorDID: String
  public let previewText: String?
  public let createdAt: Date?

  public init(uri: String, cid: String? = nil, authorDID: String, previewText: String? = nil, createdAt: Date? = nil) {
    self.uri = uri
    self.cid = cid
    self.authorDID = authorDID
    self.previewText = previewText
    self.createdAt = createdAt
  }

  enum CodingKeys: String, CodingKey {
    case uri
    case cid
    case authorDID = "author_did"
    case previewText = "preview_text"
    case createdAt = "created_at"
  }
}

// MARK: - Link Embed

/// Link/URL preview embed
public struct MLSLinkEmbed: Codable, Sendable, Hashable {
  public let url: String
  public let title: String?
  public let description: String?
  public let thumbnailURL: String?
  public let domain: String?

  public init(url: String, title: String? = nil, description: String? = nil, thumbnailURL: String? = nil, domain: String? = nil) {
    self.url = url
    self.title = title
    self.description = description
    self.thumbnailURL = thumbnailURL
    self.domain = domain
  }

  enum CodingKeys: String, CodingKey {
    case url
    case title
    case description
    case thumbnailURL = "thumbnail_url"
    case domain
  }
}

// MARK: - GIF Embed

/// Tenor GIF embed
public struct MLSGIFEmbed: Codable, Sendable, Hashable {
  public let tenorURL: String
  public let mp4URL: String
  public let title: String?
  public let thumbnailURL: String?
  public let width: Int?
  public let height: Int?

  public init(tenorURL: String, mp4URL: String, title: String? = nil, thumbnailURL: String? = nil, width: Int? = nil, height: Int? = nil) {
    self.tenorURL = tenorURL
    self.mp4URL = mp4URL
    self.title = title
    self.thumbnailURL = thumbnailURL
    self.width = width
    self.height = height
  }

  enum CodingKeys: String, CodingKey {
    case tenorURL = "tenor_url"
    case mp4URL = "mp4_url"
    case title
    case thumbnailURL = "thumbnail_url"
    case width
    case height
  }
}

// MARK: - JSON Serialization Helpers

extension MLSEmbedData {
  /// Serialize to JSON data for storage
  public func toJSONData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }

  /// Deserialize from JSON data
  public static func fromJSONData(_ data: Data) throws -> MLSEmbedData {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MLSEmbedData.self, from: data)
  }
}
