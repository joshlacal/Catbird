//
//  SearchResultsSection.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI

/// A generic section wrapper for search results
struct ResultsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        Section {
            content()
        } header: {
            Text(title)
                .appFont(AppTextRole.headline)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.systemBackground)
        }
    }
}

/// A no results found view with customizable message
struct NoResultsView: View {
    let query: String
    let type: String
    let icon: String
    let message: String?
    let actionLabel: String?
    let action: (() -> Void)?
    let isAnimationRepeating: Bool
    
    init(
        query: String,
        type: String = "results",
        icon: String = "magnifyingglass",
        message: String? = nil,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil,
        isAnimationRepeating: Bool = true
    ) {
        self.query = query
        self.type = type
        self.icon = icon
        self.message = message
        self.actionLabel = actionLabel
        self.action = action
        self.isAnimationRepeating = isAnimationRepeating
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .appFont(size: 48)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
                .symbolEffect(.pulse, options: isAnimationRepeating ? .repeating : .nonRepeating)
            
            Text("No \(type) found for \"\(query)\"")
                .appFont(AppTextRole.headline)
            
            if let message = message {
                Text(message)
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            if let actionLabel = actionLabel, let action = action {
                Button(action: action) {
                    Text(actionLabel)
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(
                            Capsule()
                                .fill(Color.accentColor)
                        )
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)  // Compromise between 40 and 60
        .padding(.horizontal)
    }
}

#Preview("Results Section") {
    VStack(spacing: 16) {
        ResultsSection(title: "Profiles") {
            Text("Profile results would go here")
                .padding()
        }
        
        EnhancedResultsSection(
            title: "Popular Feeds",
            icon: "rectangle.on.rectangle.angled",
            count: 5
        ) {
            Text("Feed results would go here")
                .padding()
        }
    }
    .padding(.vertical)
}

#Preview("No Results") {
    NoResultsView(
        query: "nonexistent123",
        type: "profiles",
        icon: "person.slash",
        message: "Try a different search term or check your spelling",
        actionLabel: "Clear Search",
        action: { }
    )
    .padding()
}
