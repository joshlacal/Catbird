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
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
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
    }
    
    // SRCH-008: Individual search row with swipe-to-delete
    @ViewBuilder
    private func searchRow(_ search: String) -> some View {
        Button {
            onSelect(search)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
                
                Text(search)
                    .appFont(AppTextRole.body)
                    .lineLimit(1)
                    .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                
                Spacer()
                
                Image(systemName: "arrow.up.left")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(Color(uiColor: .tertiaryLabel))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(Color.systemBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation {
                    onDelete(search)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        
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
                .foregroundColor(Color(uiColor: .tertiaryLabel))
            
            VStack(alignment: .leading, spacing: 4) {
                Text("No Recent Searches")
                    .appFont(AppTextRole.subheadline.weight(.medium))
                    .foregroundColor(.secondary)
                
                Text("Your search history will appear here")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(Color(uiColor: .tertiaryLabel))
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

private extension View {
    @ViewBuilder
    func applySearchHistoryGlassEffectIfAvailable() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.modifier(SearchHistoryGlassEffectModifier())
        } else {
            self
        }
    }
}

/// Extension to handle recent searches persistence
extension RecentSearchesSection {
    /// Get recently used search terms from UserDefaults
    static func getRecentSearches() -> [String] {
        if let searches = UserDefaults(suiteName: "group.blue.catbird.shared")?.array(forKey: "recentSearches") as? [String] {
            return searches
        }
        return []
    }
    
    /// Save a recent search term to UserDefaults
    static func saveRecentSearch(_ search: String) {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        var searches = getRecentSearches()
        
        // Remove if already exists (to avoid duplicates)
        if let index = searches.firstIndex(of: trimmed) {
            searches.remove(at: index)
        }
        
        // Add to the beginning
        searches.insert(trimmed, at: 0)
        
        // Limit to max 20 recent searches
        if searches.count > 20 {
            searches = Array(searches.prefix(20))
        }
        
        UserDefaults(suiteName: "group.blue.catbird.shared")?.set(searches, forKey: "recentSearches")
    }
    
    /// Clear all recent searches
    static func clearRecentSearches() {
        UserDefaults(suiteName: "group.blue.catbird.shared")?.removeObject(forKey: "recentSearches")
    }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
    RecentSearchesSection(
        searches: ["bluesky", "atproto", "trending", "blockchain", "pets"],
        onSelect: { _ in },
        onDelete: { _ in },
        onClear: { }
    )
    .padding()
}
