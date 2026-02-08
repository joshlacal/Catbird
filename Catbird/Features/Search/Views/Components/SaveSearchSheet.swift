//
//  SaveSearchSheet.swift
//  Catbird
//
//  Created on 10/13/25.
//  SRCH-015: Save current search with custom name
//

import SwiftUI

/// Sheet view for saving a search with a custom name
struct SaveSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    let query: String
    let filters: AdvancedSearchParams
    let onSave: (String) -> Void
    
    @State private var searchName = ""
    @State private var enableNotifications = false
    @FocusState private var isNameFieldFocused: Bool
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Search Name", text: $searchName)
                        .focused($isNameFieldFocused)
                        .appFont(AppTextRole.body)
                    
                    HStack {
                        Text("Query")
                            .appFont(AppTextRole.subheadline)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Text(query)
                            .appFont(AppTextRole.body)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                } header: {
                    Text("Search Details")
                } footer: {
                    Text("Give this search a memorable name for quick access later")
                }
                
                if hasActiveFilters {
                    Section {
                        activeFiltersView
                    } header: {
                        Text("Active Filters")
                    }
                }
                
                Section {
                    Toggle(isOn: $enableNotifications) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable Notifications")
                                .appFont(AppTextRole.body)
                            
                            Text("Get notified when new results appear")
                                .appFont(AppTextRole.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Notifications")
                }
                .disabled(true) // Future feature
            }
            .navigationTitle("Save Search")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveSearch()
                    }
                    .disabled(searchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Auto-generate name suggestion
                if searchName.isEmpty {
                    searchName = generateSearchName()
                }
                
                // Focus the text field
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isNameFieldFocused = true
                }
            }
        }
    }
    
    @ViewBuilder
    private var activeFiltersView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !filters.languages.isEmpty {
                filterRow(icon: "globe", title: "Languages", value: filters.languages.joined(separator: ", "))
            }
            
            if filters.dateRange != .anytime {
                filterRow(icon: "calendar", title: "Date Range", value: filters.dateRange.displayName)
            }
            
            if filters.excludeReplies {
                filterRow(icon: "bubble.left.and.bubble.right.fill", title: "Exclude Replies", value: "Yes")
            }
            
            if filters.excludeReposts {
                filterRow(icon: "arrow.2.squarepath", title: "Exclude Reposts", value: "Yes")
            }
            
            if filters.mustHaveMedia {
                filterRow(icon: "photo", title: "Media Required", value: "Yes")
            }
            
            if filters.onlyFromFollowing {
                filterRow(icon: "person.2.fill", title: "From Following", value: "Yes")
            }
            
            if filters.onlyVerified {
                filterRow(icon: "checkmark.seal.fill", title: "Verified Only", value: "Yes")
            }
            
            if filters.sortBy != .latest {
                filterRow(icon: "arrow.up.arrow.down", title: "Sort By", value: filters.sortBy.displayName)
            }
        }
    }
    
    @ViewBuilder
    private func filterRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.accentColor)
                .frame(width: 24, height: 24)
            
            Text(title)
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .appFont(AppTextRole.subheadline.weight(.medium))
                .foregroundColor(.primary)
        }
    }
    
    private var hasActiveFilters: Bool {
        return !filters.languages.isEmpty ||
               filters.dateRange != .anytime ||
               filters.excludeReplies ||
               filters.excludeReposts ||
               filters.mustHaveMedia ||
               filters.onlyFromFollowing ||
               filters.onlyVerified ||
               filters.sortBy != .latest
    }
    
    private func generateSearchName() -> String {
        // Try to generate a smart name based on query and filters
        var name = query.capitalized
        
        if query.count > 30 {
            name = String(query.prefix(30)) + "..."
        }
        
        if !filters.languages.isEmpty {
            name += " (\(filters.languages.first ?? ""))"
        } else if filters.dateRange != .anytime {
            name += " (\(filters.dateRange.displayName))"
        }
        
        return name
    }
    
    private func saveSearch() {
        let trimmedName = searchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        onSave(trimmedName)
        dismiss()
    }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
    SaveSearchSheet(
        query: "artificial intelligence",
        filters: AdvancedSearchParams(),
        onSave: { _ in }
    )
}
