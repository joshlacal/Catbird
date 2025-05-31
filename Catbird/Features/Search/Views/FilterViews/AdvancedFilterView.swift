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
                // Content Filtering Section
                Section(header: Text("Content Filters"), footer: Text("Control what types of content appear in your search results")) {
                    Toggle("Exclude Replies", isOn: $advancedParams.excludeReplies)
                    Toggle("Exclude Reposts", isOn: $advancedParams.excludeReposts)
                    Toggle("Exclude Mentions", isOn: $advancedParams.excludeMentions)
                    Toggle("Include Quotes", isOn: $advancedParams.includeQuotes)
                    Toggle("Must have media", isOn: $advancedParams.mustHaveMedia)
                    Toggle("Must have links", isOn: $advancedParams.hasLinks)
                    Toggle("Include Adult Content", isOn: $advancedParams.includeNSFW)
                }
                
                // Engagement Filters Section
                Section(header: Text("Engagement Filters"), footer: Text("Filter by minimum engagement levels")) {
                    HStack {
                        Text("Min Likes")
                        Spacer()
                        TextField("0", value: $advancedParams.minLikes, format: .number)
                            .keyboardType(.numberPad)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 80)
                    }
                    
                    HStack {
                        Text("Min Reposts")
                        Spacer()
                        TextField("0", value: $advancedParams.minReposts, format: .number)
                            .keyboardType(.numberPad)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 80)
                    }
                    
                    HStack {
                        Text("Min Replies")
                        Spacer()
                        TextField("0", value: $advancedParams.minReplies, format: .number)
                            .keyboardType(.numberPad)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 80)
                    }
                }
                
                // User Filtering Section
                Section(header: Text("User Filters"), footer: Text("Narrow down results based on user characteristics")) {
                    Toggle("Only from people I follow", isOn: $advancedParams.onlyFromFollowing)
                    Toggle("Include my followers", isOn: $advancedParams.includeFollowers)
                    Toggle("Only verified accounts", isOn: $advancedParams.onlyVerified)
                    Toggle("Exclude blocked users", isOn: $advancedParams.excludeBlockedUsers)
                    Toggle("Exclude muted users", isOn: $advancedParams.excludeMutedUsers)
                    
                    HStack {
                        Text("Min Follower Count")
                        Spacer()
                        TextField("0", value: $advancedParams.minFollowerCount, format: .number)
                            .keyboardType(.numberPad)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .frame(width: 100)
                    }
                }
                
                // Date Range Section
                Section(header: Text("Date Range"), footer: Text("Filter results by date")) {
                    Picker("Date Range", selection: $advancedParams.dateRange) {
                        ForEach(AdvancedSearchParams.DateRange.allCases) { range in
                            Text(range.displayName).tag(range)
                        }
                    }
                    
                    if advancedParams.dateRange == .custom {
                        DatePicker("Start Date", selection: Binding(
                            get: { advancedParams.customStartDate ?? Date() },
                            set: { advancedParams.customStartDate = $0 }
                        ), displayedComponents: .date)
                        
                        DatePicker("End Date", selection: Binding(
                            get: { advancedParams.customEndDate ?? Date() },
                            set: { advancedParams.customEndDate = $0 }
                        ), displayedComponents: .date)
                    }
                }
                
                // Sorting and Ranking Section
                Section(header: Text("Sorting & Ranking"), footer: Text("Choose how results are ranked and ordered")) {
                    Picker("Sort By", selection: $advancedParams.sortBy) {
                        ForEach(AdvancedSearchParams.SortOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    
                    Picker("Relevance Boost", selection: $advancedParams.relevanceBoost) {
                        ForEach(AdvancedSearchParams.RelevanceBoost.allCases) { boost in
                            Text(boost.displayName).tag(boost)
                        }
                    }
                    
                    Toggle("Prioritize Recent Content", isOn: $advancedParams.prioritizeRecent)
                }
                
                // Location Filtering Section
                Section(header: Text("Location Filtering"), footer: Text("Find content near a specific location")) {
                    TextField("Near location (optional)", text: Binding(
                        get: { advancedParams.nearLocation ?? "" },
                        set: { advancedParams.nearLocation = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    
                    if advancedParams.nearLocation != nil && !advancedParams.nearLocation!.isEmpty {
                        HStack {
                            Text("Radius (km)")
                            Spacer()
                            TextField("50", value: $advancedParams.radiusKm, format: .number)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 80)
                        }
                    }
                }
                
                // Excluded Words Section
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
