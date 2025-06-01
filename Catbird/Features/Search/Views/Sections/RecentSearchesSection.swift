//
//  RecentSearchesSection.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI

/// A section displaying recent search queries with interactive chips
struct RecentSearchesSection: View {
    let searches: [String]
    let onSelect: (String) -> Void
    let onClear: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent Searches")
                    .appFont(.customSystemFont(size: 17, weight: .bold, width: 120, relativeTo: .headline))

                Spacer()
                
                Button("Clear", action: onClear)
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(searches.prefix(10), id: \.self) { search in
                        Button {
                            onSelect(search)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "magnifyingglass")
                                    .appFont(AppTextRole.caption2)
                                
                                Text(search)
                                    .appFont(AppTextRole.subheadline)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .background(
                                Capsule()
                                    .fill(Color(.secondarySystemBackground))
                            )
                        }
                        .shadow(color: Color(.systemGray4), radius: 2, x: 0, y: 1)
                        .padding(.vertical, 2)  
                        .buttonStyle(.plain)
                        .foregroundColor(.primary)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// Extension to handle recent searches persistence
extension RecentSearchesSection {
    /// Get recently used search terms from UserDefaults
    static func getRecentSearches() -> [String] {
        if let searches = UserDefaults(suiteName: "group.blue.catbird.shared")?.array(forKey: "recentSearches") as? [String] {
            return searches
        }
        return []
    }
    
    /// Save a recent search term to UserDefaults
    static func saveRecentSearch(_ search: String) {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        var searches = getRecentSearches()
        
        // Remove if already exists (to avoid duplicates)
        if let index = searches.firstIndex(of: trimmed) {
            searches.remove(at: index)
        }
        
        // Add to the beginning
        searches.insert(trimmed, at: 0)
        
        // Limit to max 20 recent searches
        if searches.count > 20 {
            searches = Array(searches.prefix(20))
        }
        
        UserDefaults(suiteName: "group.blue.catbird.shared")?.set(searches, forKey: "recentSearches")
    }
    
    /// Clear all recent searches
    static func clearRecentSearches() {
        UserDefaults(suiteName: "group.blue.catbird.shared")?.removeObject(forKey: "recentSearches")
    }
}

#Preview {
    RecentSearchesSection(
        searches: ["bluesky", "atproto", "trending", "blockchain", "pets"],
        onSelect: { _ in },
        onClear: { }
    )
    .padding()
}
