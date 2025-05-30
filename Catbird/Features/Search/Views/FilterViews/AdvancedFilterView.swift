//
//  AdvancedFilterView.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel

/// Advanced search filter view with more options
struct AdvancedFilterView: View {
    @Environment(\.dismiss) private var dismiss
    var viewModel: RefinedSearchViewModel
    
    // Local state for advanced filters
    @State private var advancedParams = AdvancedSearchParams()
    @State private var excludedWordsText: String = ""
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Content Filters"), footer: Text("Control what types of content appear in your search results")) {
                    Toggle("Exclude Replies", isOn: $advancedParams.excludeReplies)
                    Toggle("Exclude Reposts", isOn: $advancedParams.excludeReposts)
                    Toggle("Exclude Mentions", isOn: $advancedParams.excludeMentions)
                    Toggle("Include Adult Content", isOn: $advancedParams.includeNSFW)
                }
                
                Section(header: Text("User Filters"), footer: Text("Narrow down results based on user characteristics")) {
                    Toggle("Only from people I follow", isOn: $advancedParams.onlyFromFollowing)
                    Toggle("Include my followers", isOn: $advancedParams.includeFollowers)
                    Toggle("Only verified accounts", isOn: $advancedParams.onlyVerified)
                }
                
                Section(header: Text("Sorting"), footer: Text("Choose how results are ordered")) {
                    Picker("Sort By", selection: $advancedParams.sortByLatest) {
                        Text("Latest").tag(true)
                        Text("Relevance").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                
                Section(header: Text("Excluded Words"), footer: Text("Results containing these words will be filtered out (comma separated)")) {
                    TextEditor(text: $excludedWordsText)
                        .frame(minHeight: 100)
                        .onChange(of: excludedWordsText) { _, newValue in
                            // Parse excluded words into array
                            let words = newValue.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            advancedParams.excludedWords = words
                        }
                }
                
                Section {
                    Button("Apply Advanced Filters") {
                        applyAdvancedFilters()
                        dismiss()
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .cornerRadius(8)
                    
                    Button("Reset to Defaults") {
                        resetToDefaults()
                    }
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            .navigationTitle("Advanced Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Initialize with current advanced filters
                loadCurrentFilters()
            }
        }
    }
    
    // Load current filters from the view model
    private func loadCurrentFilters() {
        advancedParams = viewModel.advancedParams
        
        // Convert excluded words array to comma-separated string
        excludedWordsText = advancedParams.excludedWords.joined(separator: ", ")
    }
    
    // Apply advanced filters to the view model
    private func applyAdvancedFilters() {
        viewModel.applyAdvancedFilters(advancedParams)
    }
    
    // Reset all advanced filters to defaults
    private func resetToDefaults() {
        advancedParams = AdvancedSearchParams()
        excludedWordsText = ""
    }
}

#Preview {
    // Create a mock view model for preview
    let appState = AppState()
    let viewModel = RefinedSearchViewModel(appState: appState)
    
    return AdvancedFilterView(viewModel: viewModel)
}
