//
//  RecentSearchesSection.swift
//  Catbird
//
//  Created on 3/9/25.
//  Updated for G05: Structured query + filter state persistence and active filter badges.
//

import SwiftUI

/// A section displaying recent search queries with active filter badges and swipe-to-delete (G05).
public struct RecentSearchesSection: View {
  public let entries: [RecentSearchEntry]
  public let onSelect: (RecentSearchEntry) -> Void
  public let onDelete: (RecentSearchEntry) -> Void
  public let onClear: () -> Void

  @State private var showClearConfirmation = false
  @State private var revealedEntryId: UUID?
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  private static let deleteRevealWidth: CGFloat = 80

  public init(
    entries: [RecentSearchEntry],
    onSelect: @escaping (RecentSearchEntry) -> Void,
    onDelete: @escaping (RecentSearchEntry) -> Void,
    onClear: @escaping () -> Void
  ) {
    self.entries = entries
    self.onSelect = onSelect
    self.onDelete = onDelete
    self.onClear = onClear
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        HStack(spacing: 6) {
          Image(systemName: "clock.arrow.circlepath")
            .appFont(AppTextRole.subheadline)
            .foregroundColor(.accentColor)

          Text("Recent Searches")
            .appFont(.customSystemFont(size: 17, weight: .bold, width: 120, relativeTo: .headline))
        }

        Spacer()

        Button {
          showClearConfirmation = true
        } label: {
          Label("Clear", systemImage: "xmark.circle.fill")
            .appFont(AppTextRole.subheadline)
            .foregroundColor(.accentColor)
            .labelStyle(.titleOnly)
        }
        .disabled(entries.isEmpty)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 8)

      if !entries.isEmpty {
        VStack(spacing: 0) {
          ForEach(entries.prefix(10)) { entry in
            searchRow(entry)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.systemBackground)
      } else {
        emptyStateView
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
    .onChange(of: entries) { _, newValue in
      if let current = revealedEntryId, !newValue.contains(where: { $0.id == current }) {
        revealedEntryId = nil
      }
    }
  }

  @ViewBuilder
  private func searchRow(_ entry: RecentSearchEntry) -> some View {
    let isRevealed = revealedEntryId == entry.id
    let filterCount = entry.filters.activeFilterCount

    ZStack(alignment: .trailing) {
      // Underlay delete action
      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          revealedEntryId = nil
          onDelete(entry)
        }
      } label: {
        Label("Delete", systemImage: "trash")
          .labelStyle(.iconOnly)
          .foregroundStyle(.white)
          .frame(width: Self.deleteRevealWidth)
          .frame(maxHeight: .infinity)
          .background(Color.red)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Delete \(entry.query)")
      .opacity(isRevealed ? 1 : 0)

      Button {
        if isRevealed {
          withAnimation(.easeInOut(duration: 0.2)) { revealedEntryId = nil }
        } else {
          onSelect(entry)
        }
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "magnifyingglass")
            .appFont(AppTextRole.subheadline)
            .foregroundColor(.secondary)
            .frame(width: 20, height: 20)

          Text(entry.query)
            .appFont(AppTextRole.body)
            .lineLimit(1)
            .foregroundColor(
              Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))

          if filterCount > 0 {
            HStack(spacing: 3) {
              Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 11))
              Text("\(filterCount)")
                .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundColor(.accentColor)
            .background(Color.accentColor.opacity(0.15))
            .clipShape(Capsule())
            .accessibilityLabel("\(filterCount) active filters")
          }

          Spacer()

          Image(systemName: "arrow.up.left")
            .appFont(AppTextRole.caption)
            .foregroundColor(Color(platformColor: PlatformColor.platformTertiaryLabel))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color.systemBackground)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .offset(x: isRevealed ? -Self.deleteRevealWidth : 0)
      .simultaneousGesture(
        DragGesture(minimumDistance: 12)
          .onEnded { value in
            let horizontal = value.translation.width
            let vertical = value.translation.height
            guard abs(horizontal) > abs(vertical) else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
              if horizontal < -40 {
                revealedEntryId = entry.id
              } else if horizontal > 40 {
                revealedEntryId = nil
              }
            }
          }
      )
    }
    .clipped()

    if entry.id != entries.prefix(10).last?.id {
      Divider()
    }
  }

  private var emptyStateView: some View {
    HStack(spacing: 12) {
      Image(systemName: "magnifyingglass")
        .appFont(size: 24)
        .foregroundColor(Color(platformColor: PlatformColor.platformTertiaryLabel))

      VStack(alignment: .leading, spacing: 4) {
        Text("No Recent Searches")
          .appFont(AppTextRole.subheadline.weight(.medium))
          .foregroundColor(.secondary)

        Text("Your search history will appear here")
          .appFont(AppTextRole.caption)
          .foregroundColor(Color(platformColor: PlatformColor.platformTertiaryLabel))
      }

      Spacer()
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.systemBackground)
  }
}
