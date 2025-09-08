import Foundation
import Petrel

/// Helpers for extracting and lightly normalizing text for embeddings
enum EmbeddingTextExtractor {
    /// Returns the primary text to embed for a cached feed item.
    /// For MVP, this is the post's own text (not the thread or parent).
    static func text(for cached: CachedFeedViewPost, includeQuoted: Bool = true) -> String? {
        let fvp = cached.feedViewPost
        guard case .knownType(let record) = fvp.post.record,
              let post = record as? AppBskyFeedPost else {
            return nil
        }
        var raw = post.text
        if includeQuoted, let quoted = quotedText(from: fvp) {
            raw = raw.isEmpty ? quoted : "\(raw): \(quoted)"
        }
        let cleaned = clean(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Light cleaning to reduce noise for embeddings (URLs and mentions)
    private static func clean(_ text: String) -> String {
        var s = text
        // Replace URLs with a placeholder
        s = s.replacingOccurrences(of: "https?://\\S+", with: "[link]", options: .regularExpression)
        // Replace mentions with a placeholder
        s = s.replacingOccurrences(of: "(?<!\\w)@[A-Za-z0-9_\\.:-]+", with: "@user", options: .regularExpression)
        // Collapse whitespace
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Attempt to extract quoted post text from embed unions.
    private static func quotedText(from feed: AppBskyFeedDefs.FeedViewPost) -> String? {
        guard let embed = feed.post.embed else { return nil }
        switch embed {
        case .appBskyEmbedRecordView(let recordView):
            switch recordView.record {
            case .appBskyEmbedRecordViewRecord(let viewRecord):
                if case let .knownType(rec) = viewRecord.value, let feedPost = rec as? AppBskyFeedPost {
                    return feedPost.text
                }
            default: break
            }
        case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
            switch recordWithMediaView.record.record {
            case .appBskyEmbedRecordViewRecord(let viewRecord):
                if case let .knownType(rec) = viewRecord.value, let feedPost = rec as? AppBskyFeedPost {
                    return feedPost.text
                }
            default: break
            }
        default: break
        }
        return nil
    }
}
