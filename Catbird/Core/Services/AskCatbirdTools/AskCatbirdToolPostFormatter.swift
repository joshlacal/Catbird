import Foundation
import Petrel

/// The model-facing shape of a post in Ask Catbird read results.
///
/// Read results share a small context window, so each post carries only what
/// helps an answer: who wrote it, when, the authored text, engagement, short
/// media descriptions and quoted text. Storage identities other than the post
/// identifier (CIDs, DIDs, reply references) are left out, and coverage that is
/// the same for every post is stated once per result rather than per post.
enum AskCatbirdToolPostFormatter {
  /// A post is at most 300 graphemes, so this keeps whole posts and bounds quotes.
  static let textLimit = 300
  static let quotedTextLimit = 300
  static let mediaTextLimit = 200

  static let coverage = """
  Post text, attachment descriptions, link previews and quoted posts only. Images, video and \
  linked pages were not inspected. Counts are as of retrieval. A post's id (such as p3) is for tool \
  arguments and citation links like [@alice](p3), never visible text.
  """

  struct Quoted: Encodable, Equatable {
    var author: String?
    var text: String?
    var textTruncated: Bool?
    var media: [String]?
    var status: String?
  }

  struct Post: Encodable, Equatable {
    let id: String
    var author: String?
    var authorName: String?
    var posted: String?
    var text: String?
    var textTruncated: Bool?
    var isReply: Bool?
    var likes: Int?
    var reposts: Int?
    var replies: Int?
    var quotes: Int?
    var media: [String]?
    var quotedPosts: [Quoted]?
    var notes: [String]?
    var contentStatus: String?
  }

  struct List: Encodable {
    let posts: [Post]
    let coverage: String
  }

  /// Per-post coverage the builder adds for every post; it is stated once per result.
  private static let sharedCoverage: Set<String> = [
    "Snapshot of supplied post and available quoted records only; reply parent/root identifiers are not their contents.",
    "Media contains supplied alt text and link previews only. Images, video, audio, captions and linked pages were not inspected."
  ]

  /// JSON for a list of posts with one shared coverage statement.
  static func list(_ posts: [AppBskyFeedDefs.PostView], refs: AskCatbirdPostRefs? = nil, now: Date = Date()) -> String {
    let items = posts.map { view in
      post(view, id: refs?.ref(for: view.uri.uriString()), now: now)
    }
    return CopilotPrompt.sourceJSON(List(posts: items, coverage: coverage))
  }

  static func post(_ view: AppBskyFeedDefs.PostView, textLimit: Int = textLimit, id: String? = nil, now: Date = Date()) -> Post {
    post(CopilotPostEvidenceBuilder.build(view), view: view, textLimit: textLimit, id: id, now: now)
  }

  /// `id` names the post for the model; it defaults to the post's AT URI.
  static func post(
    _ evidence: CopilotPostEvidence, view: AppBskyFeedDefs.PostView, textLimit: Int = textLimit,
    id: String? = nil, now: Date = Date()
  ) -> Post {
    let selected = evidence.selectedPost
    var result = Post(id: id ?? selected.uri)
    result.author = selected.authorHandle.map { "@" + $0 }
    result.authorName = selected.authorName.flatMap { $0.isEmpty ? nil : $0 }
    if case .knownType(let record) = view.record, let body = record as? AppBskyFeedPost {
      result.posted = age(of: body.createdAt.date, now: now)
      result.isReply = body.reply == nil ? nil : true
    }
    if let text = selected.text {
      result.text = String(text.prefix(textLimit))
      result.textTruncated = selected.textTruncated || text.count > textLimit ? true : nil
    }
    result.likes = positive(view.likeCount)
    result.reposts = positive(view.repostCount)
    result.replies = positive(view.replyCount)
    result.quotes = positive(view.quoteCount)
    result.media = describe(selected.media)
    result.notes = notes(selected.coverage + evidence.coverage)
    if selected.contentStatus != .available {
      result.contentStatus = "\(selected.contentStatus.rawValue); do not infer its contents"
    }
    let quoted = evidence.quotedPosts.map(quote)
    result.quotedPosts = quoted.isEmpty ? nil : quoted
    return result
  }

  /// The post as a JSON object, for callers that add fields such as thread position.
  static func dictionary(_ post: Post) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(post),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return ["id": post.id, "contentStatus": "unavailable; do not infer its contents"]
    }
    return object
  }

  private static func quote(_ post: CopilotPostEvidence.Post) -> Quoted {
    guard post.contentStatus == .available else {
      return Quoted(author: post.authorHandle.map { "@" + $0 },
                    status: "\(post.contentStatus.rawValue); contents unknown")
    }
    var quoted = Quoted(author: post.authorHandle.map { "@" + $0 })
    if let text = post.text {
      quoted.text = String(text.prefix(quotedTextLimit))
      quoted.textTruncated = post.textTruncated || text.count > quotedTextLimit ? true : nil
    }
    quoted.media = describe(post.media)
    return quoted
  }

  private static func describe(_ media: [CopilotPostEvidence.Media]) -> [String]? {
    let lines = media.map { item -> String in
      func short(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.count > mediaTextLimit ? String(value.prefix(mediaTextLimit)) + "…" : value
      }
      switch item.kind {
      case .image: return short(item.altText).map { "image: \($0)" } ?? "image (no description)"
      case .video: return short(item.altText).map { "video: \($0)" } ?? "video (no description)"
      case .externalLink:
        let label = [short(item.title), short(item.description)].compactMap { $0 }.joined(separator: " — ")
        let link = item.uri.map { " <\($0)>" } ?? ""
        return "link: " + (label.isEmpty ? "untitled" : label) + link
      }
    }
    return lines.isEmpty ? nil : lines
  }

  private static func notes(_ coverage: [String]) -> [String]? {
    var seen = Set<String>()
    let notes = coverage.filter { !sharedCoverage.contains($0) && seen.insert($0).inserted }
    return notes.isEmpty ? nil : notes
  }

  private static func positive(_ value: Int?) -> Int? {
    guard let value, value > 0 else { return nil }
    return value
  }

  /// A short age such as "5m", "3h", "2d" or an ISO date for older posts.
  static func age(of date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "just now"
    case ..<3_600: return "\(Int(seconds / 60))m ago"
    case ..<86_400: return "\(Int(seconds / 3_600))h ago"
    case ..<(86_400 * 30): return "\(Int(seconds / 86_400))d ago"
    default:
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withFullDate]
      return formatter.string(from: date)
    }
  }
}
