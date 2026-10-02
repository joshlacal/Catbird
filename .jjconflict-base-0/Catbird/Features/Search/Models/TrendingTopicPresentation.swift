import Foundation
import Petrel

/// Presentation policy for descriptions supplied by Bluesky's trending-topics API.
///
/// Catbird deliberately does not synthesize a replacement when the service omits a
/// description. That keeps the topic UI attributable to Bluesky and removes a model
/// invocation from discovery's hot path.
enum TrendingTopicPresentation {
    static func description(for topic: AppBskyUnspeccedDefs.TrendView) -> String? {
        guard let rawDescription = topic.description else { return nil }

        let withoutMarkup = rawDescription.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let normalized = withoutMarkup
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalized.isEmpty ? nil : normalized
    }

    static func matchesMutedText(
        _ mutedText: String,
        topic: AppBskyUnspeccedDefs.TrendView
    ) -> Bool {
        let needle = mutedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }

        let searchableText = [
            topic.topic,
            topic.displayName,
            topic.category,
            description(for: topic),
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        return searchableText.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }
}
