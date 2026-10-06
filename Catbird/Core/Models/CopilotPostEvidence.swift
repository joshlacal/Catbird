import Foundation

/// Source material, never instructions. This snapshot contains only already-loaded data.
struct CopilotPostEvidence: Codable, Hashable, Sendable {
  enum ContentStatus: String, Codable, Hashable, Sendable {
    case available, unreadable, notFound, blocked, detached, omitted
  }

  struct Media: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case image, video, externalLink }
    let kind: Kind
    var altText: String?
    var uri: String?
    var title: String?
    var description: String?
    var truncatedFields: [String] = []
  }

  struct Post: Codable, Hashable, Sendable {
    let uri: String
    var cid: String?
    var authorDID: String?
    var authorHandle: String?
    var authorName: String?
    var text: String?
    var textTruncated = false
    var replyToURI: String?
    var rootURI: String?
    var quotedPostURI: String?
    var media: [Media] = []
    var contentStatus: ContentStatus = .available
    var coverage: [String] = []
  }

  let selectedPost: Post
  let quotedPosts: [Post]
  let coverage: [String]

  /// JSON escaping preserves authored newlines/quotes as data. Escaping angle brackets
  /// also prevents source text from closing an enclosing prompt delimiter.
  var promptDescription: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else {
      return #"{"coverage":["Post evidence could not be encoded."]}"#
    }
    return String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "<", with: #"\u003C"#)
      .replacingOccurrences(of: ">", with: #"\u003E"#)
  }

  var sources: [CopilotSource] {
    var seen = Set<String>()
    return ([selectedPost] + quotedPosts).compactMap { post in
      guard post.contentStatus == .available, seen.insert(post.uri).inserted else { return nil }
      let author = post.authorHandle.map { "@" + $0 } ?? post.authorName ?? "Post"
      let excerpt = post.text.map { String($0.prefix(80)).replacingOccurrences(of: "\n", with: " ") } ?? ""
      return CopilotSource(label: excerpt.isEmpty ? author : "\(author): \(excerpt)", uri: post.uri)
    }
  }
}
