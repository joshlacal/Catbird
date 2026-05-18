//
//  RecentSearchesSection.swift
//  Catbird
//
//  Created on 3/9/25.
//  SRCH-008: Enhanced with swipe-to-delete and improved clear functionality
//

import SwiftUI

/// A section displaying recent search queries with interactive chips and swipe-to-delete
struct RecentSearchesSection: View {
  let searches: [String]
  let onSelect: (String) -> Void
  let onDelete: (String) -> Void  // SRCH-008: Individual delete callback
  let onClear: () -> Void

  @State private var showClearConfirmation = false  // SRCH-008: Confirmation dialog
  @State private var revealedSearch: String?
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  private static let deleteRevealWidth: CGFloat = 80

  var body: some View {
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
        .disabled(searches.isEmpty)
      }
      .padding(0)

      // SRCH-008: List-based layout with swipe-to-delete
      if !searches.isEmpty {
        VStack(spacing: 0) {
          ForEach(searches.prefix(10), id: \.self) { search in
            searchRow(search)
          }
        }
        .background(Color.systemBackground)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 4, y: 2)
        .padding(.horizontal)
      } else {
        emptyStateView
          .padding(.horizontal)
      }
    }
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
    .onChange(of: searches) { _, newValue in
      if let current = revealedSearch, !newValue.contains(current) {
        revealedSearch = nil
      }
    }
  }

  // Individual search row. `.searchSuggestions` does not host us inside a real
  // SwiftUI List, so SwiftUI's `.swipeActions` modifier falls through to the
  // enclosing system row and stacks one delete button per recent-search row.
  // Implement the swipe-to-reveal manually so each delete affects only its row.
  @ViewBuilder
  private func searchRow(_ search: String) -> some View {
    let isRevealed = revealedSearch == search
    ZStack(alignment: .trailing) {
      // Underlay delete action, revealed by swipe.
      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          revealedSearch = nil
          onDelete(search)
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
      .accessibilityLabel("Delete \(search)")
      .opacity(isRevealed ? 1 : 0)

      Button {
        if isRevealed {
          withAnimation(.easeInOut(duration: 0.2)) { revealedSearch = nil }
        } else {
          onSelect(search)
        }
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "magnifyingglass")
            .appFont(AppTextRole.subheadline)
            .foregroundColor(.secondary)
            .frame(width: 20, height: 20)

          Text(search)
            .appFont(AppTextRole.body)
            .lineLimit(1)
            .foregroundColor(
              Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))

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
                revealedSearch = search
              } else if horizontal > 40 {
                revealedSearch = nil
              }
            }
          }
      )
    }
    .clipped()

    if search != searches.prefix(10).last {
      Divider()
        .padding(.leading, 48)
    }
  }

  // SRCH-008: Empty state for when no recent searches
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
    .background(Color.systemBackground)
    .cornerRadius(12)
    .overlay(
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(Color.separator.opacity(0.5), lineWidth: 1)
    )
  }
}

// MARK: - iOS 26 Liquid Glass Support

@available(iOS 26.0, macOS 26.0, *)
@available(iOS 26.0, macOS 26.0, *)
private struct SearchHistoryGlassEffectModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .glassEffect(.regular, in: .rect(cornerRadius: 12))
  }
}

extension View {
  @ViewBuilder
  fileprivate func applySearchHistoryGlassEffectIfAvailable() -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      self.modifier(SearchHistoryGlassEffectModifier())
    } else {
      self
    }
  }
}

#Preview {
  AsyncPreviewContent { appState in
    RecentSearchesSection(
        searches: ["bluesky", "atproto", "trending", "blockchain", "pets"],
        onSelect: { _ in },
        onDelete: { _ in },
        onClear: {}
      )
      .padding()
  }
}

