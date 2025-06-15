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
    
    private let logger = Logger(subsystem: "blue.catbird", category: "TypeaheadView")
    
    var body: some View {
        VStack(spacing: 0) {
            if committed {
                // Show loading indicators when a search is committed but still loading
                LoadingRowsView(count: 5)
            } else if searchText.isEmpty {
                // Show empty state if no search text
                emptyStateView
            } else {
                // Show typeahead suggestions
                suggestionsList
            }
            
            Spacer(minLength: 50)
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
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                // Profiles Section
                if !viewModel.typeaheadProfiles.isEmpty {
                    ForEach(viewModel.typeaheadProfiles, id: \.did) { profile in
                        Button {
                            // Save to recent profiles and navigate
                            viewModel.addRecentProfileSearchBasic(profile: profile)
                            path.append(NavigationDestination.profile(profile.did.didString()))
                        } label: {
                            ProfileRowView(profile: profile)
                                .padding(.horizontal)
                        }
                        .buttonStyle(.plain)
                        
                        if profile != viewModel.typeaheadProfiles.last {
                            Divider()
                                .padding(.leading, 68) // Align with profile content
                        }
                    }
                }
                
                // Search directly button - always show
                Button {
                    // Commit search with current text
                    guard let client = appState.atProtoClient else {
                        logger.error("Empty client")
                        return
                    }

                    viewModel.commitSearch(client: client)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.accentColor)
                            .frame(width: 44, height: 44)
                        
                        Text("Search for \"\(searchText)\"")
                            .foregroundColor(.accentColor)
                            .fontWeight(.medium)
                            .appFont(AppTextRole.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, viewModel.typeaheadProfiles.isEmpty ? 0 : 8)
            }
            .background(Color(.systemBackground))
        }
    }
    
}
