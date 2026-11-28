import Petrel
import SwiftUI

/// Compact App Store "Top Charts" feed row: crisp 46pt icon, 1-line title, 1-line subtitle,
/// and instant optimistic `+` / `✓` pill button. Keeps icons small to avoid low-res avatar blowout.
struct FeedStorefrontRow: View {
  let feed: AppBskyFeedDefs.GeneratorView
  var customSubtitle: String?
  let onSelect: () -> Void
  let onOpen: () -> Void

  private var subtitleText: String {
    if let customSubtitle, !customSubtitle.isEmpty {
      return customSubtitle
    }
    if let desc = feed.description?
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !desc.isEmpty {
      return desc
    }
    let creatorHandle = feed.creator.handle.description
    if let likes = feed.likeCount, likes > 0 {
      if likes < 1_000 {
        return String(
          localized: "@\(creatorHandle) · \(likes) likes",
          comment: "Feed row subtitle with creator handle and like count — first variable is handle, second is number of likes"
        )
      }
      let compactLikes = FeedCountFormatter.compact(likes)
      return String(
        localized: "@\(creatorHandle) · \(compactLikes) likes",
        comment: "Feed row subtitle with creator handle and compact like count — first variable is handle, second is compact count like 1.2K"
      )
    }
    return "@\(creatorHandle)"
  }

  var body: some View {
    HStack(alignment: .center, spacing: Space.md) {
      Button(action: onSelect) {
        HStack(alignment: .center, spacing: Space.md) {
          StorefrontFeedIcon(feed: feed, size: 46)

          VStack(alignment: .leading, spacing: Space.hairline) {
            Text(feed.displayName)
              .appFont(AppTextRole.subheadline)
              .fontWeight(.semibold)
              .foregroundStyle(.primary)
              .lineLimit(1)

            Text(subtitleText)
              .appFont(AppTextRole.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(feed.displayName), \(subtitleText)")
      .accessibilityHint("Opens live preview and details")
      .accessibilityIdentifier("feed.storefront.row.\(feed.uri.uriString())")

      FeedLibraryButton(feed: feed, size: .compact, onOpen: onOpen)
    }
    .padding(.vertical, Space.xs)
  }
}

/// Crisp small-format feed icon with subtle hairline border and gradient monogram fallback.
struct StorefrontFeedIcon: View {
  let feed: AppBskyFeedDefs.GeneratorView
  let size: CGFloat

  private var cornerRadius: CGFloat {
    size * 0.22
  }

  var body: some View {
    AsyncImage(url: feed.avatar.flatMap { URL(string: $0.uriString()) }) { phase in
      switch phase {
      case .success(let image):
        image
          .resizable()
          .scaledToFill()
      default:
        monogramPlaceholder
      }
    }
    .frame(width: size, height: size)
    .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
    )
    .accessibilityHidden(true)
  }

  private var monogramPlaceholder: some View {
    ZStack {
      LinearGradient(
        colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      Text(String(feed.displayName.prefix(1)).uppercased())
        .appFont(size: size * 0.42, weight: .bold, relativeTo: .headline)
        .foregroundStyle(.white)
    }
  }
}

/// App Store-style 3-row horizontal paging carousel (`.scrollTargetBehavior(.viewAligned)`).
/// Users scan 9–12 feeds in two seconds with peeking next-column affordance.
struct FeedStorefrontCarousel<Item: Identifiable>: View {
  let items: [Item]
  var rowsPerColumn: Int = 3
  let feedForItem: (Item) -> AppBskyFeedDefs.GeneratorView
  var subtitleForItem: (Item) -> String? = { _ in nil }
  let onSelect: (AppBskyFeedDefs.GeneratorView) -> Void
  let onOpen: (AppBskyFeedDefs.GeneratorView) -> Void

  private var columns: [[Item]] {
    FeedStorefrontViewModel.chunkIntoColumns(items, rowsPerColumn: rowsPerColumn)
  }

  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(alignment: .top, spacing: Space.md) {
        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(column.enumerated()), id: \.element.id) { rowIndex, item in
              let feed = feedForItem(item)
              FeedStorefrontRow(
                feed: feed,
                customSubtitle: subtitleForItem(item),
                onSelect: { self.onSelect(feed) },
                onOpen: { self.onOpen(feed) }
              )
              if rowIndex < column.count - 1 {
                Divider()
                  .padding(.leading, 58)
              }
            }
          }
          .containerRelativeFrame(.horizontal) { width, _ in
            // Leave a ~36pt peek of the next column on compact screens; cap neatly on iPad/macOS.
            min(max(width - 44, 260), 360)
          }
        }
      }
      .scrollTargetLayout()
      .padding(.horizontal, Space.lg)
    }
    .scrollIndicators(.hidden)
    .scrollTargetBehavior(.viewAligned)
  }
}

/// Section header for a Storefront shelf with an optional "See All" navigation affordance.
struct FeedShelfHeader: View {
  let title: String
  var subtitle: String?
  var onSeeAll: (() -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
      VStack(alignment: .leading, spacing: Space.hairline) {
        Text(title)
          .appFont(AppTextRole.title3)
          .fontWeight(.bold)
          .foregroundStyle(.primary)
          .accessibilityAddTraits(.isHeader)

        if let subtitle, !subtitle.isEmpty {
          Text(subtitle)
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: Space.sm)

      if let onSeeAll {
        Button(action: onSeeAll) {
          HStack(spacing: Space.hairline) {
            Text("See All")
              .appFont(AppTextRole.subheadline)
            Image(systemName: "chevron.forward")
              .appFont(AppTextRole.caption)
              .fontWeight(.semibold)
          }
          .foregroundStyle(Color.accentColor)
          .frame(minHeight: ControlHeight.minHitTarget)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("See all \(title)")
      }
    }
    .padding(.horizontal, Space.lg)
  }
}

enum FeedCountFormatter {
  static func compact(_ count: Int) -> String {
    if count >= 1_000_000 {
      let millions = Double(count) / 1_000_000.0
      return "\(millions.formatted(.number.precision(.fractionLength(1))))M"
    } else if count >= 1_000 {
      let thousands = Double(count) / 1_000.0
      return "\(thousands.formatted(.number.precision(.fractionLength(1))))K"
    } else {
      return count.formatted()
    }
  }
}
