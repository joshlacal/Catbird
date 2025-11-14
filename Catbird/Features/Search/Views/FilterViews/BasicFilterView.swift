//
//  BasicFilterView.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel

/// Enum representing date filter options
enum FilterDate: String, CaseIterable {
    case anytime = "anytime"
    case today = "today"
    case week = "week"
    case month = "month"
    case year = "year"
    
    var displayName: String {
        switch self {
        case .anytime: return "Anytime"
        case .today: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        case .year: return "This year"
        }
    }
    
    var icon: String {
        switch self {
        case .anytime: return "clock"
        case .today: return "calendar.day.timeline.left"
        case .week: return "calendar.badge.clock"
        case .month: return "calendar"
        case .year: return "calendar.circle"
        }
    }
}

/// Enum representing content type filter options
enum ContentType: String, CaseIterable {
    case all = "all"
    case profiles = "profiles"
    case posts = "posts"
    case feeds = "feeds"
//    case starterPacks = "starterPacks"
    
    var title: String {
        switch self {
        case .all: return "All"
        case .profiles: return "Profiles"
        case .posts: return "Posts"
        case .feeds: return "Feeds"
//        case .starterPacks: return "Starter Packs"
        }
    }
    
    var icon: String {
        switch self {
        case .all: return "rectangle.grid.2x2"
        case .profiles: return "person"
        case .posts: return "text.bubble"
        case .feeds: return "rectangle.grid.1x2"
//        case .starterPacks: return "person.3"
        }
    }
    
    var emptyIcon: String {
        switch self {
        case .all: return "magnifyingglass"
        case .profiles: return "person.slash"
        case .posts: return "text.bubble.slash"
        case .feeds: return "rectangle.slash"
//        case .starterPacks: return "person.3.fill"
        }
    }
}

/// Enum for search result sorting options  
enum SearchSort: String, CaseIterable {
    case top = "top"
    case latest = "latest"
    
    var displayName: String {
        switch self {
        case .top: return "Top"
        case .latest: return "Latest"
        }
    }
    
    var icon: String {
        switch self {
        case .top: return "star.fill"
        case .latest: return "clock.fill"
        }
    }
    
    var description: String {
        switch self {
        case .top: return "Most relevant and popular results"
        case .latest: return "Most recent results first"
        }
    }
}

/// Model for language selection options
struct LanguageOption: Identifiable, Hashable {
    let id = UUID()
    let code: String
    let name: String
    let isPreferred: Bool
    
    var displayName: String {
        // Just display the name as is, since we don't have nativeName in this struct
        return name
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(code)
    }
    
    static func == (lhs: LanguageOption, rhs: LanguageOption) -> Bool {
        return lhs.code == rhs.code
    }
    
    static let supportedLanguages: [LanguageOption] = [
        LanguageOption(code: "en", name: "English", isPreferred: true),
        LanguageOption(code: "es", name: "Spanish", isPreferred: false),
        LanguageOption(code: "ja", name: "Japanese", isPreferred: false),
        LanguageOption(code: "de", name: "German", isPreferred: false),
        LanguageOption(code: "fr", name: "French", isPreferred: false),
        LanguageOption(code: "pt", name: "Portuguese", isPreferred: false),
        LanguageOption(code: "ru", name: "Russian", isPreferred: false),
        LanguageOption(code: "zh", name: "Chinese", isPreferred: false),
        LanguageOption(code: "ko", name: "Korean", isPreferred: false),
        LanguageOption(code: "ar", name: "Arabic", isPreferred: false),
        LanguageOption(code: "hi", name: "Hindi", isPreferred: false),
        LanguageOption(code: "it", name: "Italian", isPreferred: false)
    ]
}

/// Basic filter view for search results
struct FilterView: View {
    @Environment(\.dismiss) private var dismiss
    var viewModel: RefinedSearchViewModel
    
    // Local state for the filters
    @State private var selectedDate = FilterDate.anytime
    @State private var selectedContentTypes: Set<ContentType> = []
    @State private var selectedLanguages: Set<String> = []
    @State private var allLanguages: [LanguageOption] = LanguageOption.supportedLanguages
    
    var body: some View {
        NavigationView {
            Form {
                Section("Date") {
                    ForEach(FilterDate.allCases, id: \.self) { date in
                        Button {
                            selectedDate = date
                        } label: {
                            HStack {
                                Image(systemName: date.icon)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 24)
                                
                                Text(date.displayName)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                if selectedDate == date {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                        .symbolEffect(.pulse, options: .nonRepeating, value: selectedDate)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Section("Content Types") {
                    ForEach(ContentType.allCases, id: \.self) { contentType in
                        Button {
                            toggleContentType(contentType)
                        } label: {
                            HStack {
                                Image(systemName: contentType.icon)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 24)
                                
                                Text(contentType.title)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                if selectedContentTypes.contains(contentType) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Section("Languages") {
                    // Sort languages - preferred first, then alphabetically
                    let sortedLanguages = allLanguages.sorted {
                        if $0.isPreferred && !$1.isPreferred {
                            return true
                        } else if !$0.isPreferred && $1.isPreferred {
                            return false
                        } else {
                            return $0.name < $1.name
                        }
                    }
                    
                    ForEach(sortedLanguages) { language in
                        languageRow(for: language)
                    }
                }
                
                Section {
                    Button("Apply Filters") {
                        // Apply filters to view model
                        viewModel.applyFilters(
                            date: selectedDate,
                            contentTypes: selectedContentTypes,
                            languages: selectedLanguages
                        )
                        dismiss()
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .cornerRadius(8)
                    
                    Button("Reset Filters") {
                        selectedDate = .anytime
                        selectedContentTypes = []
                        selectedLanguages = []
                    }
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }
            .navigationTitle("Filters")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                // Initialize with current filters
                selectedDate = viewModel.filterDate
                selectedContentTypes = viewModel.filterContentTypes
                selectedLanguages = viewModel.filterLanguages
            }
        }
    }
    
    // Toggle content type selection
    private func toggleContentType(_ contentType: ContentType) {
        if selectedContentTypes.contains(contentType) {
            selectedContentTypes.remove(contentType)
        } else {
            selectedContentTypes.insert(contentType)
        }
    }
    
    // Helper method for language row
    private func languageRow(for language: LanguageOption) -> some View {
        Button {
            if selectedLanguages.contains(language.code) {
                selectedLanguages.remove(language.code)
            } else {
                selectedLanguages.insert(language.code)
            }
        } label: {
            HStack {
                Text(language.name)
                    .foregroundColor(.primary)
                
                if language.isPreferred {
                    Text("Preferred")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.1))
                        )
                }
                
                Spacer()
                
                if selectedLanguages.contains(language.code) {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
    // Create a mock view model for preview

    
     FilterView(viewModel: RefinedSearchViewModel(appState: appState))
}
