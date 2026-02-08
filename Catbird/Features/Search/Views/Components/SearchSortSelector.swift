//
//  SearchSortSelector.swift
//  Catbird
//
//  Top/Latest sort selector for search results
//

import SwiftUI

/// Sort selector component for search results
struct SearchSortSelector: View {
    @Binding var selectedSort: SearchSort
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        HStack {
            Text("Sort by:")
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Menu {
                ForEach(SearchSort.allCases, id: \.self) { sort in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            selectedSort = sort
                        }
                    } label: {
                        Label(sort.displayName, systemImage: sort.icon)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedSort.icon)
                        .appFont(AppTextRole.footnote)
                        .foregroundColor(.accentColor)
                    
                    Text(selectedSort.displayName)
                        .appFont(AppTextRole.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
                    
                    Image(systemName: "chevron.down")
                        .appFont(AppTextRole.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Color.accentColor.opacity(0.1),
                    in: Capsule()
                )
            }
            .animation(.snappy(duration: 0.2), value: selectedSort)
        }
    }
}

/// Alternative segmented control style sort selector
struct SearchSortSegmentedControl: View {
    @Binding var selectedSort: SearchSort
    
    var body: some View {
        Picker("Sort", selection: $selectedSort) {
            ForEach(SearchSort.allCases, id: \.self) { sort in
                HStack(spacing: 4) {
                    Image(systemName: sort.icon)
                        .appFont(AppTextRole.caption2)
                    Text(sort.displayName)
                        .appFont(AppTextRole.caption)
                }
                .tag(sort)
            }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Preview

#Preview {
    @Previewable @Environment(AppState.self) var appState
    @State var selectedSort = SearchSort.top
    
    return VStack(spacing: 20) {
        SearchSortSelector(selectedSort: $selectedSort)
        SearchSortSegmentedControl(selectedSort: $selectedSort)
    }
    .padding()
    .environment(AppStateManager.shared)
}
