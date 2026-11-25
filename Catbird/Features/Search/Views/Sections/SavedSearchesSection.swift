//
//  SavedSearchesSection.swift
//  Catbird
//
//  Created on 10/13/25.
//  SRCH-015: Saved Searches
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
    @Environment(\.locale) private var locale
    
    var body: some View {
        if !savedSearches.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                DiscoverySectionHeader("Saved Searches") {
                    if savedSearches.count > 3 {
                        Button(action: onShowAll) {
                            Label("All Saved", systemImage: "chevron.forward")
                                .labelStyle(DisclosureLinkLabelStyle())
                                .appFont(size: Typography.Size.subheadline, weight: .medium, relativeTo: .subheadline)
                                .frame(minHeight: 44)
                        }
                    }
                }

                VStack(spacing: 0) {
                    ForEach(Array(savedSearches.prefix(3).enumerated()), id: \.element.id) { index, search in
                        savedSearchRow(search)
                        
                        if index < min(2, savedSearches.count - 1) {
                            Divider()
                        }
                    }
                }
                .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
            }
        }
    }
    
    @ViewBuilder
    private func savedSearchRow(_ search: SavedSearch) -> some View {
        Button {
            onSelect(search)
        } label: {
            savedSearchLabel(search)
        }
        .buttonStyle(.plain)
        .accessibilityAction(named: Text("Delete", comment: "Accessibility action to delete a saved search")) {
            withAnimation {
                onDelete(search)
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
    
    private func savedSearchLabel(_ search: SavedSearch) -> some View {
            HStack(spacing: 12) {
                Image(systemName: "bookmark.fill")
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.purple)
                    .frame(width: 20, height: 20)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(search.name)
                        .appFont(AppTextRole.body.weight(.medium))
                        .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                        .lineLimit(2)
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text(search.query)
                            .appFont(AppTextRole.caption)
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                            .lineLimit(1)
                        
                        Text(
                            "Last used \(formatLastUsed(search.lastUsed))",
                            comment: "Relative time when a saved search was last used — variable is a relative time phrase"
                        )
                            .appFont(AppTextRole.caption2)
                            .foregroundStyle(.secondary)

                        if search.filters.activeFilterCount > 0 {
                            Text(
                                "\(search.filters.activeFilterCount) filters",
                                comment: "Number of active filters saved with a search"
                            )
                                .appFont(AppTextRole.caption)
                                .foregroundColor(Color(platformColor: PlatformColor.platformTertiaryLabel))
                        }
                    }
                }
                
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
    }

    private func formatLastUsed(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: Date())
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
    @Environment(\.locale) private var locale
    
    let savedSearches: [SavedSearch]
    let onSelect: (SavedSearch) -> Void
    let onDelete: (SavedSearch) -> Void
    
    @State private var searchFilter = ""
    @State private var sortOption: SortOption = .recent
    
    enum SortOption: String, CaseIterable {
        case recent = "Recently Used"
        case name = "Name"
        case created = "Date Created"

        var localizedTitle: LocalizedStringResource {
            switch self {
            case .recent:
                return LocalizedStringResource("Recently Used", comment: "Sort option for saved searches by last used time")
            case .name:
                return LocalizedStringResource("Name", comment: "Sort option for saved searches alphabetically by name")
            case .created:
                return LocalizedStringResource("Date Created", comment: "Sort option for saved searches by creation date")
            }
        }
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
                                Text(option.localizedTitle).tag(option)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort")
                }
                
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
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
                            Label {
                                Text(
                                    "Created \(formatDate(search.createdAt))",
                                    comment: "Creation date of a saved search — variable is a formatted date"
                                )
                            } icon: {
                                Image(systemName: "calendar")
                            }
                                .appFont(AppTextRole.caption2)
                                .foregroundColor(Color(platformColor: PlatformColor.platformTertiaryLabel))
                            
                            Label {
                                Text(
                                    "Used \(formatLastUsed(search.lastUsed))",
                                    comment: "Relative time when a saved search was last used — variable is a relative time phrase"
                                )
                            } icon: {
                                Image(systemName: "clock")
                            }
                                .appFont(AppTextRole.caption2)
                                .foregroundColor(Color(platformColor: PlatformColor.platformTertiaryLabel))
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
    private func filtersPreview(_ filters: SearchFilterState) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if filters.sort != .top {
                    filterChip(icon: "arrow.up.arrow.down", text: localizedSortName(filters.sort))
                }
                
                ForEach(filters.summaryItems(locale: locale)) { item in
                    filterChip(icon: item.icon, text: item.text)
                }
            }
        }
    }

    private func localizedSortName(_ sort: SearchSort) -> String {
        var resource = sort.localizedDisplayName
        resource.locale = locale
        return String(localized: resource)
    }
    
    @ViewBuilder
    private func filterChip(icon: String, text: String) -> some View {
        CatbirdChip(title: Text(text), systemImage: icon, size: .sm)
    }
    
    private func hasActiveFilters(_ filters: SearchFilterState) -> Bool {
        filters.sort != .top || !filters.summaryItems(locale: locale).isEmpty
    }
    
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bookmark.slash")
                .appFont(size: 48)
                .foregroundColor(.secondary)
            
            Text("No Saved Searches")
                .appFont(AppTextRole.headline)
            
            Text(
                searchFilter.isEmpty
                    ? LocalizedStringResource("Save your frequent searches for quick access.", comment: "Empty state description when no saved searches exist")
                    : LocalizedStringResource("No searches match “\(searchFilter)”.", comment: "Empty state description when filtering saved searches yields no matches — variable is the filter query")
            )
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    private func formatLastUsed(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }
    
    private func formatDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day().locale(locale))
    }
}

#Preview("Saved Searches Section") {
    let sampleSearches = [
        SavedSearch(name: "AI News", query: "artificial intelligence", filters: SearchFilterState()),
        SavedSearch(name: "Local Events", query: "events near me", filters: SearchFilterState()),
        SavedSearch(name: "Tech Updates", query: "technology", filters: SearchFilterState())
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
        SavedSearch(name: "AI News", query: "artificial intelligence", filters: SearchFilterState()),
        SavedSearch(name: "Local Events", query: "events near me", filters: SearchFilterState()),
        SavedSearch(name: "Tech Updates", query: "technology", filters: SearchFilterState())
    ]
    
    AllSavedSearchesView(
        savedSearches: sampleSearches,
        onSelect: { _ in },
        onDelete: { _ in }
    )
}
