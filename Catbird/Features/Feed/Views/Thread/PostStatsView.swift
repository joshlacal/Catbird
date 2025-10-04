//
//  PostStatsView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/26/25.
//

import SwiftUI
import Petrel

struct PostStatsView: View {
    let post: AppBskyFeedDefs.PostView
    @Binding var path: NavigationPath
    
    private static let baseUnit: CGFloat = 3
    
    // Only display if any stat is available
    private var hasAnyStats: Bool {
        (post.replyCount != nil && post.replyCount! > 0) ||
        (post.repostCount != nil && post.repostCount! > 0) ||
        (post.likeCount != nil && post.likeCount! > 0) ||
        (post.quoteCount != nil && post.quoteCount! > 0)
    }
    
    var body: some View {
        if hasAnyStats {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                    .padding(.horizontal, Self.baseUnit * 2)
                
                FlowLayout(
                    horizontalSpacing: Self.baseUnit * 4,
                    verticalSpacing: Self.baseUnit * 4
                ) {
                    // Replies stat
                    if let replyCount = post.replyCount, replyCount > 0 {
                        HStack(spacing: 4) {
                            Text("\(replyCount)")
                                .fontWeight(.semibold)
                            Text(statLabel(for: replyCount, singular: "reply", plural: "replies"))
                                .foregroundColor(.secondary)
                        }
                    }

                    // Reposts stat with tap gesture
                    if let repostCount = post.repostCount, repostCount > 0 {
                        HStack(spacing: 4) {
                            Text("\(repostCount)")
                                .fontWeight(.semibold)
                            Text(statLabel(for: repostCount, singular: "repost"))
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            path.append(NavigationDestination.postReposts(post.uri.uriString()))
                        }
                    }
                    
                    // Likes stat with tap gesture
                    if let likeCount = post.likeCount, likeCount > 0 {
                        HStack(spacing: 4) {
                            Text("\(likeCount)")
                                .fontWeight(.semibold)
                            Text(statLabel(for: likeCount, singular: "like"))
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            path.append(NavigationDestination.postLikes(post.uri.uriString()))
                        }
                    }
                    
                    // Quotes stat with tap gesture
                    if let quoteCount = post.quoteCount, quoteCount > 0 {
                        HStack(spacing: 4) {
                            Text("\(quoteCount)")
                                .fontWeight(.semibold)
                            Text(statLabel(for: quoteCount, singular: "quote"))
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            path.append(NavigationDestination.postQuotes(post.uri.uriString()))
                        }
                    }
                }
                .padding(.top, Self.baseUnit * 2)
                .padding(.horizontal, Self.baseUnit * 2)
                .padding(.vertical, Self.baseUnit * 3)
                .appFont(AppTextRole.headline)
                
                Divider()
                    .padding(.horizontal, Self.baseUnit * 2)
                    .padding(.vertical, Self.baseUnit * 2)
            }
        } else {
            // No stats available – render nothing
            EmptyView()
        }
    }
}

private extension PostStatsView {
    /// Returns a localized-friendly stat label given the count and base word.
    func statLabel(for count: Int, singular: String, plural: String? = nil) -> String {
        let resolvedPlural = plural ?? singular + "s"
        return count == 1 ? singular : resolvedPlural
    }
}

/// A layout that arranges views in a horizontal flow, wrapping to the next line when needed.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat
    var alignment: FlowAlignment = .leading

    enum FlowAlignment {
        case leading, center, trailing
    }

     struct Cache {
        var sizes: [CGSize] = []
        var maxItemWidth: CGFloat = 0
        fileprivate var metrics: FlowMetrics?
        var lastResolvedWidth: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        let measuredSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if cache.sizes != measuredSizes {
            cache.sizes = measuredSizes
            cache.maxItemWidth = measuredSizes.map { $0.width }.max() ?? 0
            cache.metrics = nil
        }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        updateCache(&cache, subviews: subviews)

        guard !cache.sizes.isEmpty else { return .zero }

        let resolvedWidth = resolveWidth(from: proposal, cache: &cache)
        let metrics = metrics(forWidth: resolvedWidth, cache: &cache)
        return metrics.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        updateCache(&cache, subviews: subviews)

        guard !cache.sizes.isEmpty else { return }

        let targetWidth = max(bounds.width, cache.maxItemWidth)
        let metrics = metrics(forWidth: targetWidth, cache: &cache)

        var y = bounds.minY

        for (lineIndex, line) in metrics.lines.enumerated() {
            var x = bounds.minX + horizontalOffset(for: line.width, in: bounds.width)

            for index in line.range {
                let subview = subviews[index]
                let size = cache.sizes[index]
                let proposal = ProposedViewSize(width: size.width, height: size.height)

                subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: proposal
                )

                x += size.width + horizontalSpacing
            }

            y += line.height
            if lineIndex != metrics.lines.indices.last {
                y += verticalSpacing
            }
        }
    }

    private func resolveWidth(from proposal: ProposedViewSize, cache: inout Cache) -> CGFloat {
        if let width = proposal.width, width.isFinite {
            let minimum = max(cache.maxItemWidth, 0)
            cache.lastResolvedWidth = max(width, minimum)
            return cache.lastResolvedWidth ?? width
        }

        if let cachedWidth = cache.lastResolvedWidth, cachedWidth.isFinite {
            return max(cachedWidth, cache.maxItemWidth)
        }

        let fallback = max(cache.maxItemWidth, 0)
        cache.lastResolvedWidth = fallback
        return fallback
    }

    private func metrics(forWidth width: CGFloat, cache: inout Cache) -> FlowMetrics {
        if let metrics = cache.metrics, metrics.width == width {
            return metrics
        }

        let adjustedWidth = max(width, cache.maxItemWidth)
        let sizes = cache.sizes

        var lines: [FlowMetrics.Line] = []
        var lineStart = sizes.startIndex
        var currentLineWidth: CGFloat = 0
        var currentLineHeight: CGFloat = 0

        func appendLine(endingAt endIndex: Int) {
            guard endIndex > lineStart else { return }
            let line = FlowMetrics.Line(
                range: lineStart..<endIndex,
                width: currentLineWidth,
                height: currentLineHeight
            )
            lines.append(line)
            lineStart = endIndex
            currentLineWidth = 0
            currentLineHeight = 0
        }

        for (index, size) in sizes.enumerated() {
            let exceedsLine = currentLineWidth > 0 && currentLineWidth + horizontalSpacing + size.width > adjustedWidth
            if exceedsLine {
                appendLine(endingAt: index)
            }

            let spacing = currentLineWidth == 0 ? 0 : horizontalSpacing
            currentLineWidth += spacing + size.width
            currentLineHeight = max(currentLineHeight, size.height)
        }

        appendLine(endingAt: sizes.endIndex)

        let maxLineWidth = lines.map { $0.width }.max() ?? 0
        let totalHeight = lines.reduce(0) { $0 + $1.height } + verticalSpacing * CGFloat(max(lines.count - 1, 0))

        let metrics = FlowMetrics(
            width: adjustedWidth,
            lines: lines,
            size: CGSize(width: maxLineWidth, height: totalHeight)
        )

        cache.metrics = metrics
        cache.lastResolvedWidth = adjustedWidth
        return metrics
    }

    private func horizontalOffset(for lineWidth: CGFloat, in containerWidth: CGFloat) -> CGFloat {
        switch alignment {
        case .leading:
            return 0
        case .center:
            return max((containerWidth - lineWidth) / 2, 0)
        case .trailing:
            return max(containerWidth - lineWidth, 0)
        }
    }
}

private struct FlowMetrics {
    struct Line {
        let range: Range<Int>
        let width: CGFloat
        let height: CGFloat
    }

    let width: CGFloat
    let lines: [Line]
    let size: CGSize
}
