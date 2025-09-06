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
    let committed: Bool
    @Environment(AppState.self) private var appState
    private let baseUnit: CGFloat = 3
    
    private let logger = Logger(subsystem: "blue.catbird", category: "TypeaheadView")
    
    var body: some View {
        Group {
            if committed {
                // While a committed search is loading, show a lightweight skeleton list
                List {
                    Section {
                        LoadingRowsView(count: 5)
                            .redacted(reason: .placeholder)
                            .mainContentFrame()
                            .listRowInsets(EdgeInsets())
                    }
                }
                .listStyle(.plain)
            } else if searchText.isEmpty {
                emptyStateView
            } else {
                suggestionsList
            }
        }
        .animation(.smooth(duration: 0.2), value: viewModel.typeaheadResultsCount)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .appFont(size: 48)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
                .padding(.top, 60)
            
            Text("Start typing to search")
                .appFont(AppTextRole.headline)
            
            Text("Search for handles, feeds, hashtags, or keywords")
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }
    
    private var suggestionsList: some View {
        List {
            // Profiles Section
            if !viewModel.typeaheadProfiles.isEmpty {
                Section("Profiles") {
                    let items = viewModel.typeaheadProfiles
                    ForEach(items, id: \.did) { profile in
                        VStack(spacing: 0) {
                            ProfileRowView(profile: profile, path: $path)
                                .padding(.top, baseUnit * 3)
                                .onTapGesture {
                                    viewModel.addRecentProfileSearchBasic(profile: profile)
                                }

                            if profile != items.last {
                                Rectangle()
                                    .fill(Color.separator)
                                    .frame(height: 0.5)
                                    .platformIgnoresSafeArea(.container, edges: .horizontal)
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                }
            }

            // Direct search row
            Section {
                Button {
                    guard let client = appState.atProtoClient else {
                        logger.error("Empty client")
                        return
                    }
                    viewModel.commitSearch(client: client)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.accentColor)
                            .frame(width: 20, height: 20)
                        Text("Search for \"\(searchText)\"")
                            .foregroundColor(.accentColor)
                            .fontWeight(.medium)
                            .appFont(AppTextRole.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
    }
    
}
