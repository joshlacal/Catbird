import Foundation

#if os(iOS)

// MARK: - Message Payload

/// Encrypted message payload structure for MLS messages
/// This structure is encoded to JSON and then encrypted
struct MLSMessagePayload: Codable {
  /// Protocol version for future compatibility
  let version: Int = 1

  /// Message text content
  let text: String

  /// Optional embed data (record, link, or GIF)
  let embed: MLSEmbedData?

  init(text: String, embed: MLSEmbedData? = nil) {
    self.text = text
    self.embed = embed
  }
}

// MARK: - Payload Encoding/Decoding

extension MLSMessagePayload {
  /// Encode payload to JSON data for encryption
  func encodeToJSON() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }

  /// Decode payload from JSON data after decryption
  static func decodeFromJSON(_ data: Data) throws -> MLSMessagePayload {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(MLSMessagePayload.self, from: data)
  }
}

#endif
