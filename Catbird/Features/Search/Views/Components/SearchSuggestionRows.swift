import SwiftUI

// MARK: - Suggestion Row

/// A compact, leading-aligned suggestion row: a fixed-width glyph column and one line of text.
struct SearchSuggestionRow<Title: View>: View {
  let systemImage: String
  let tint: Color
  @ViewBuilder let title: () -> Title

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .appFont(AppTextRole.body)
        .foregroundStyle(tint)
        .frame(width: 24)
        .accessibilityHidden(true)
      title()
        .appFont(AppTextRole.body)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 44)
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }
}

/// Native search suggestions render in a list; Catbird rows own their own insets and spacing.
struct SearchSuggestionRowModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
  }
}

// MARK: - Empty History

/// Shown while the field is focused with no query and no search history yet.
struct SearchHistoryEmptyHint: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Search Bluesky")
        .appFont(AppTextRole.headline)
      Text("Find people, posts, and feeds. Try a name, a #hashtag, or from:handle.")
        .appFont(AppTextRole.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text("Profiles you view and searches you make will appear here.")
        .appFont(AppTextRole.footnote)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 6)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 16)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("search.history.empty")
  }
}
