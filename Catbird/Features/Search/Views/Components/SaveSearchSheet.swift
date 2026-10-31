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
    let filters: SearchFilterState
    let onSave: (String) -> Void
    
    @State private var searchName = ""
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
                    Text("Give this search a memorable name for quick access later.")
                }
                
                if hasActiveFilters {
                    Section {
                        activeFiltersView
                    } header: {
                        Text("Active Filters")
                    }
                }
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
            if filters.sort != .top {
                filterRow(icon: "arrow.up.arrow.down", text: "Sorted by \(filters.sort.displayName)")
            }
            
            ForEach(filters.summaryItems) { item in
                filterRow(icon: item.icon, text: item.text)
            }
        }
    }
    
    @ViewBuilder
    private func filterRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.accentColor)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            
            Text(text)
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.primary)
            
            Spacer(minLength: 0)
        }
    }
    
    private var hasActiveFilters: Bool {
        filters.sort != .top || !filters.summaryItems.isEmpty
    }
    
    private func generateSearchName() -> String {
        // Keep the user's own casing ("iOS", "#WWDC"); only shorten long queries.
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = trimmed.count > 30 ? String(trimmed.prefix(30)) + "…" : trimmed
        
        if let summary = filters.summaryItems.first {
            name += " (\(summary.text))"
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
  AsyncPreviewContent { appState in
    SaveSearchSheet(
            query: "artificial intelligence",
            filters: SearchFilterState(),
            onSave: { _ in }
        )
  }
}
