//
//  RecentSearchesSection.swift
//  Catbird
//
//  Created on 3/9/25.
//  Updated for G05: Structured query + filter state persistence and active filter badges.
//

import SwiftUI

/// Recent search queries as compact rows with active filter badges and swipe-to-delete (G05).
public struct RecentSearchesSection: View {
  public let entries: [RecentSearchEntry]
  public let onSelect: (RecentSearchEntry) -> Void
  public let onFill: ((RecentSearchEntry) -> Void)?
  public let onDelete: (RecentSearchEntry) -> Void
  public let onClear: () -> Void

  @State private var showClearConfirmation = false
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  private static let maximumVisibleEntries = 10

  public init(
    entries: [RecentSearchEntry],
    onSelect: @escaping (RecentSearchEntry) -> Void,
    onFill: ((RecentSearchEntry) -> Void)? = nil,
    onDelete: @escaping (RecentSearchEntry) -> Void,
    onClear: @escaping () -> Void
  ) {
    self.entries = entries
    self.onSelect = onSelect
    self.onFill = onFill
    self.onDelete = onDelete
    self.onClear = onClear
  }

  private var visibleEntries: [RecentSearchEntry] {
    Array(entries.prefix(Self.maximumVisibleEntries))
  }

  public var body: some View {
    // Each query is a native suggestion row so the list owns scroll and swipe arbitration.
    Group {
      header
      ForEach(visibleEntries) { entry in
        VStack(spacing: 0) {
          searchRow(entry)
          if entry.id != visibleEntries.last?.id {
            Rectangle()
              .fill(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme))
              .frame(height: 0.5)
              .padding(.leading, 52)
          }
        }
        .modifier(SearchSuggestionRowModifier())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
          Button(role: .destructive) { delete(entry) } label: {
            Label("Delete", systemImage: "trash")
          }
          .accessibilityLabel(
            Text(
              "Delete \(entry.query)",
              comment: "Swipe action accessibility label to delete a recent search — variable is the search query"
            )
          )
        }
      }
    }
  }

  private var header: some View {
    SearchHistoryHeader(title: "Recent Searches", clearLabel: "Clear recent searches") {
      showClearConfirmation = true
    }
    .disabled(entries.isEmpty)
    .padding(.top, 8)
    .padding(.bottom, 4)
    .modifier(SearchSuggestionRowModifier())
    .accessibilityIdentifier("search.history.queries")
    .confirmationDialog(
      "Clear Recent Searches",
      isPresented: $showClearConfirmation,
      titleVisibility: .visible
    ) {
      Button("Clear All", role: .destructive) {
        withAnimation {
          onClear()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will remove all recent searches from this device.")
    }
  }

  private func searchRow(_ entry: RecentSearchEntry) -> some View {
    HStack(spacing: 0) {
      Button {
        onSelect(entry)
      } label: {
        rowLabel(entry)
      }
      .buttonStyle(.plain)
      .accessibilityHint(Text("Searches again", comment: "Accessibility hint for tapping a recent search row"))
      .accessibilityAction(named: Text("Delete", comment: "Accessibility action to delete a recent search")) { delete(entry) }

      if let onFill {
        fillButton(entry, onFill: onFill)
      }
    }
    .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
    .contextMenu {
      Button(role: .destructive) { delete(entry) } label: {
        Label("Remove from History", systemImage: "trash")
      }
    }
  }

  /// Puts the query back in the field without searching, like Safari's history rows.
  private func fillButton(_ entry: RecentSearchEntry, onFill: @escaping (RecentSearchEntry) -> Void) -> some View {
    Button {
      onFill(entry)
    } label: {
      Image(systemName: "arrow.up.left")
        .appFont(AppTextRole.footnote)
        .foregroundStyle(.tertiary)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.trailing, 4)
    .accessibilityLabel(
      Text(
        "Edit \(entry.query)",
        comment: "Button accessibility label to place a recent search query into the search field — variable is the search query"
      )
    )
    .accessibilityHint(Text("Places this search in the search field", comment: "Accessibility hint for the fill query button on a recent search row"))
  }

  private func rowLabel(_ entry: RecentSearchEntry) -> some View {
    let filterCount = entry.filters.activeFilterCount
    return HStack(spacing: 12) {
      Image(systemName: "clock.arrow.circlepath")
        .appFont(AppTextRole.body)
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .accessibilityHidden(true)

      Text(entry.query)
        .appFont(AppTextRole.body)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(
          Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))

      if filterCount > 0 {
        CatbirdBadge(
          Text(filterCount, format: .number), systemImage: "line.3.horizontal.decrease",
          tone: .accent
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          Text(
            "\(filterCount) active filters",
            comment: "Accessibility label for badge showing how many search filters are active on a recent search"
          )
        )
      }

      Spacer(minLength: 0)
    }
    .padding(.leading, 16)
    .padding(.trailing, onFill == nil ? 16 : 0)
    .frame(minHeight: 44)
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }

  private func delete(_ entry: RecentSearchEntry) {
    withAnimation(.easeInOut(duration: 0.2)) {
      onDelete(entry)
    }
  }
}
