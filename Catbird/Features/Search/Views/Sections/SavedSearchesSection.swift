//
//  SavedSearchesSection.swift
//  Catbird
//
//  Created on 10/13/25.
//  SRCH-015: Saved Searches with Notifications
//

import SwiftUI
import Petrel

/// Section displaying saved searches with management capabilities
struct SavedSearchesSection: View {
    let savedSearches: [SavedSearch]
    let onSelect: (SavedSearch) -> Void
    let onDelete: (SavedSearch) -> Void
    let onShowAll: () -> Void
    
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        if !savedSearches.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "bookmark.fill")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.purple)
                    
                    Text("Saved Searches")
                        .appFont(.customSystemFont(size: 17, weight: .bold, width: 120, relativeTo: .headline))
                    
                    Spacer()
                    
                    if savedSearches.count > 3 {
                        Button {
                            onShowAll()
                        } label: {
                            HStack(spacing: 4) {
                                Text("See All")
                                Image(systemName: "chevron.right")
                                    .appFont(AppTextRole.caption)
                            }
                            .appFont(AppTextRole.subheadline)
                            .foregroundColor(.accentColor)
                        }
                    }
                }
                .padding(.horizontal)
                
                VStack(spacing: 0) {
                    ForEach(Array(savedSearches.prefix(3).enumerated()), id: \.element.id) { index, search in
                        savedSearchRow(search)
                        
                        if index < min(2, savedSearches.count - 1) {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
                .background(Color.elevatedBackground(appState.themeManager, elevation: .low, currentScheme: colorScheme))
                .cornerRadius(12)
                .shadow(color: Color.dynamicShadow(appState.themeManager, currentScheme: colorScheme), radius: 4, y: 2)
                .padding(.horizontal)
            }
        }
    }
    
    @ViewBuilder
    private func savedSearchRow(_ search: SavedSearch) -> some View {
        Button {
            onSelect(search)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bookmark.fill")
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.purple)
                    .frame(width: 20, height: 20)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(search.name)
                        .appFont(AppTextRole.body.weight(.medium))
                        .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        Text(search.query)
                            .appFont(AppTextRole.caption)
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                            .lineLimit(1)
                        
                        if !search.filters.languages.isEmpty {
                            Text("• \(search.filters.languages.count) filter\(search.filters.languages.count == 1 ? "" : "s")")
                                .appFont(AppTextRole.caption)
                                .foregroundColor(Color(uiColor: .tertiaryLabel))
                        }
                    }
                }
                
                Spacer()
                
                Text(formatLastUsed(search.lastUsed))
                    .appFont(AppTextRole.caption2)
                    .foregroundColor(Color(uiColor: .tertiaryLabel))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
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
        .contextMenu {
            Button {
                onSelect(search)
            } label: {
                Label("Run Search", systemImage: "magnifyingglass")
            }
            
            Button(role: .destructive) {
                onDelete(search)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private func formatLastUsed(_ date: Date) -> String {
        let now = Date()
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: date, to: now)
        
        if let days = components.day, days > 0 {
            return days == 1 ? "1d ago" : "\(days)d ago"
        } else if let hours = components.hour, hours > 0 {
            return hours == 1 ? "1h ago" : "\(hours)h ago"
        } else if let minutes = components.minute, minutes > 0 {
            return minutes == 1 ? "1m ago" : "\(minutes)m ago"
        } else {
            return "now"
        }
    }
}

// MARK: - iOS 26 Liquid Glass Support

@available(iOS 26.0, macOS 26.0, *)
@available(iOS 26.0, macOS 26.0, *)
private struct SavedSearchesGlassEffectModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
    }
}

private extension View {
    @ViewBuilder
    func applySavedSearchesGlassEffectIfAvailable() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.modifier(SavedSearchesGlassEffectModifier())
        } else {
            self
        }
    }
}

// MARK: - Full Saved Searches View

/// Full screen view for managing all saved searches
struct AllSavedSearchesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    let savedSearches: [SavedSearch]
    let onSelect: (SavedSearch) -> Void
    let onDelete: (SavedSearch) -> Void
    
    @State private var searchFilter = ""
    @State private var sortOption: SortOption = .recent
    
    enum SortOption: String, CaseIterable {
        case recent = "Recently Used"
        case name = "Name"
        case created = "Date Created"
    }
    
    private var filteredSearches: [SavedSearch] {
        var searches = savedSearches
        
        // Apply search filter
        if !searchFilter.isEmpty {
            searches = searches.filter {
                $0.name.localizedCaseInsensitiveContains(searchFilter) ||
                $0.query.localizedCaseInsensitiveContains(searchFilter)
            }
        }
        
        // Apply sorting
        switch sortOption {
        case .recent:
            searches.sort { $0.lastUsed > $1.lastUsed }
        case .name:
            searches.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .created:
            searches.sort { $0.createdAt > $1.createdAt }
        }
        
        return searches
    }
    
    var body: some View {
        NavigationStack {
            List {
                if filteredSearches.isEmpty {
                    Section {
                        emptyStateView
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(filteredSearches) { search in
                        savedSearchDetailRow(search)
                            .listRowInsets(EdgeInsets())
                    }
                }
            }
            .listStyle(.plain)
            .background(Color.dynamicGroupedBackground(appState.themeManager, currentScheme: colorScheme))
            .navigationTitle("Saved Searches")
            #if os(iOS)
            .toolbarTitleDisplayMode(.large)
            .searchable(text: $searchFilter, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search saved searches")
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort By", selection: $sortOption) {
                            ForEach(SortOption.allCases, id: \.self) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func savedSearchDetailRow(_ search: SavedSearch) -> some View {
        Button {
            onSelect(search)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "bookmark.fill")
                        .appFont(AppTextRole.title3)
                        .foregroundColor(.purple)
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(Color.purple.opacity(0.15))
                        )
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text(search.name)
                            .appFont(AppTextRole.headline.weight(.semibold))
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                        
                        Text(search.query)
                            .appFont(AppTextRole.subheadline)
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                            .lineLimit(2)
                        
                        HStack(spacing: 12) {
                            Label("Created \(formatDate(search.createdAt))", systemImage: "calendar")
                                .appFont(AppTextRole.caption2)
                                .foregroundColor(Color(uiColor: .tertiaryLabel))
                            
                            Label("Used \(formatLastUsed(search.lastUsed))", systemImage: "clock")
                                .appFont(AppTextRole.caption2)
                                .foregroundColor(Color(uiColor: .tertiaryLabel))
                        }
                        .padding(.top, 4)
                    }
                    
                    Spacer()
                }
                
                // Show active filters
                if hasActiveFilters(search.filters) {
                    filtersPreview(search.filters)
                }
            }
            .padding(16)
            .background(Color.elevatedBackground(appState.themeManager, elevation: .low, currentScheme: colorScheme))
            .cornerRadius(12)
            .padding(.horizontal)
            .padding(.vertical, 6)
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
    }
    
    @ViewBuilder
    private func filtersPreview(_ filters: AdvancedSearchParams) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !filters.languages.isEmpty {
                    filterChip(icon: "globe", text: "\(filters.languages.count) language\(filters.languages.count == 1 ? "" : "s")")
                }
                
                if filters.dateRange != .anytime {
                    filterChip(icon: "calendar", text: filters.dateRange.displayName)
                }
                
                if filters.excludeReplies {
                    filterChip(icon: "bubble.left.and.bubble.right.fill", text: "No replies")
                }
                
                if filters.mustHaveMedia {
                    filterChip(icon: "photo", text: "Has media")
                }
                
                if filters.onlyFromFollowing {
                    filterChip(icon: "person.2.fill", text: "Following")
                }
            }
        }
    }
    
    @ViewBuilder
    private func filterChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .appFont(AppTextRole.caption2)
            
            Text(text)
                .appFont(AppTextRole.caption)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(0.15))
        )
        .foregroundColor(.accentColor)
    }
    
    private func hasActiveFilters(_ filters: AdvancedSearchParams) -> Bool {
        return !filters.languages.isEmpty ||
               filters.dateRange != .anytime ||
               filters.excludeReplies ||
               filters.excludeReposts ||
               filters.mustHaveMedia ||
               filters.onlyFromFollowing
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bookmark.slash")
                .appFont(size: 48)
                .foregroundColor(.secondary)
            
            Text("No Saved Searches")
                .appFont(AppTextRole.headline)
            
            Text(searchFilter.isEmpty ? 
                 "Save your frequent searches for quick access" :
                 "No searches match '\(searchFilter)'")
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    private func formatLastUsed(_ date: Date) -> String {
        let now = Date()
        let components = Calendar.current.dateComponents([.day, .hour], from: date, to: now)
        
        if let days = components.day, days > 0 {
            return "\(days)d ago"
        } else if let hours = components.hour, hours > 0 {
            return "\(hours)h ago"
        } else {
            return "recently"
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

#Preview("Saved Searches Section") {
    let sampleSearches = [
        SavedSearch(name: "AI News", query: "artificial intelligence", filters: AdvancedSearchParams()),
        SavedSearch(name: "Local Events", query: "events near me", filters: AdvancedSearchParams()),
        SavedSearch(name: "Tech Updates", query: "technology", filters: AdvancedSearchParams())
    ]
    
    SavedSearchesSection(
        savedSearches: sampleSearches,
        onSelect: { _ in },
        onDelete: { _ in },
        onShowAll: { }
    )
    .padding()
}

#Preview("All Saved Searches") {
    let sampleSearches = [
        SavedSearch(name: "AI News", query: "artificial intelligence", filters: AdvancedSearchParams()),
        SavedSearch(name: "Local Events", query: "events near me", filters: AdvancedSearchParams()),
        SavedSearch(name: "Tech Updates", query: "technology", filters: AdvancedSearchParams())
    ]
    
    AllSavedSearchesView(
        savedSearches: sampleSearches,
        onSelect: { _ in },
        onDelete: { _ in }
    )
}
