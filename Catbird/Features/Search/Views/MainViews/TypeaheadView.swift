//
//  TypeaheadView.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel
import OSLog

/// View displaying search suggestions as the user types
struct TypeaheadView: View {
    var viewModel: RefinedSearchViewModel
    @Binding var path: NavigationPath
    @Binding var searchText: String
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    private let baseUnit: CGFloat = 3
    
    private let logger = Logger(subsystem: "blue.catbird", category: "TypeaheadView")
    
    var body: some View {
        Group {
            if viewModel.isCommittedSearch {
                // While a committed search is loading, show a lightweight skeleton list
                List {
                    Section {
                        LoadingRowsView(count: 5)
                            .redacted(reason: .placeholder)
                            .mainContentFrame()
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
            } else if searchText.isEmpty {
                emptyStateView
            } else {
                suggestionsList
            }
        }
        .animation(.smooth(duration: 0.2), value: viewModel.typeaheadResultsCount)
    }
    
    private var emptyStateView: some View {
        SearchHistoryEmptyHint()
            .mainContentFrame()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
    }
    
    private var suggestionsList: some View {
        List {
            // Direct search leads, matching the focused suggestions.
            Button {
                guard let client = appState.atProtoClient else {
                    logger.error("Empty client")
                    return
                }
                viewModel.commitSearch(client: client)
            } label: {
                SearchSuggestionRow(systemImage: "magnifyingglass", tint: .accentColor) {
                    Text("Search for “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”")
                        .foregroundStyle(Color.accentColor)
                }
                .mainContentFrame()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search.typeahead.submit")
            .modifier(SearchSuggestionRowModifier())

            // Profiles Section
            if !viewModel.typeaheadProfiles.isEmpty {
                Section("Profiles") {
                    let items = viewModel.typeaheadProfiles
                    ForEach(items, id: \.did) { profile in
                        VStack(spacing: 0) {
                            ProfileRowView(profile: profile, path: $path)
                                .mainContentFrame()
                                .padding(.top, baseUnit * 3)
                                .onTapGesture {
                                    viewModel.addRecentProfileSearchBasic(profile: profile)
                                }

                            if profile != items.last {
                                Rectangle()
                                    .fill(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme))
                                    .frame(height: 0.5)
                                    .platformIgnoresSafeArea(.container, edges: .horizontal)
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
                    }
                }
            }

        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
        .padding(0)
    }
    
}

#Preview("TypeaheadView") {
  AsyncPreviewContent { appState in
    NavigationStack {
      TypeaheadView(
        viewModel: RefinedSearchViewModel(appState: appState),
        path: .constant(NavigationPath()),
        searchText: .constant("swift")
      )
    }
  }
}
