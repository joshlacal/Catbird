//
//  SearchResultsSection.swift
//  Catbird
//
//  Created on 3/9/25.
//  SRCH-011: Enhanced error states with better recovery options
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

/// SRCH-011: Enhanced no results view with improved messaging and actions
struct NoResultsView: View {
    let query: String
    let type: String
    let icon: String
    let message: String?
    let actionLabel: String?
    let action: (() -> Void)?
    let isAnimationRepeating: Bool
    
    @State private var isAnimating = false
    
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
        VStack(spacing: 20) {
            // SRCH-011: Enhanced icon with animation
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 96, height: 96)
                    .scaleEffect(isAnimating ? 1.1 : 1.0)
                    .opacity(isAnimating ? 0.5 : 0.8)
                    .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isAnimating)
                
                Image(systemName: icon)
                    .appFont(size: 48)
                    .foregroundColor(.accentColor)
                    .symbolEffect(.pulse, options: isAnimationRepeating ? .repeating : .nonRepeating)
            }
            .padding(.bottom, 8)
            
            VStack(spacing: 8) {
                Text("No \(type) found")
                    .appFont(AppTextRole.title3.weight(.semibold))
                    .foregroundColor(.primary)
                
                // SRCH-011: Show query in a subtle way
                if !query.isEmpty {
                    Text("for \"\(query)\"")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            // SRCH-011: Enhanced help message with better formatting
            if let message = message {
                Text(message)
                    .appFont(AppTextRole.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 4)
            } else {
                // Default suggestions
                VStack(spacing: 12) {
                    suggestionRow(icon: "checkmark.circle", text: "Try different keywords")
                    suggestionRow(icon: "checkmark.circle", text: "Check your spelling")
                    suggestionRow(icon: "checkmark.circle", text: "Use fewer or more general words")
                }
                .padding(.horizontal, 32)
            }
            
            // SRCH-011: Enhanced action button with glass effect
            if let actionLabel = actionLabel, let action = action {
                Button(action: action) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                            .appFont(AppTextRole.subheadline)
                        
                        Text(actionLabel)
                            .appFont(AppTextRole.subheadline.weight(.medium))
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 24)
                    .background(
                        Capsule()
                            .fill(Color.accentColor)
                    )
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal)
        .onAppear {
            isAnimating = true
        }
    }
    
    // SRCH-011: Helper view for suggestions
    private func suggestionRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .appFont(AppTextRole.caption)
                .foregroundColor(.accentColor)
            
            Text(text)
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// SRCH-011: Enhanced error state view for search failures
struct SearchErrorView: View {
    let error: Error
    let query: String
    let retryAction: () -> Void
    
    @State private var isExpanded = false
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(spacing: 24) {
            // Error icon
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.1))
                    .frame(width: 96, height: 96)
                
                Image(systemName: "exclamationmark.triangle.fill")
                    .appFont(size: 48)
                    .foregroundColor(.red)
                    .symbolEffect(.bounce, value: error.localizedDescription)
            }
            
            VStack(spacing: 8) {
                Text("Search Failed")
                    .appFont(AppTextRole.title3.weight(.semibold))
                    .foregroundColor(.primary)
                
                Text(errorMessage)
                    .appFont(AppTextRole.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            // Action buttons
            VStack(spacing: 12) {
                Button(action: retryAction) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise")
                            .appFont(AppTextRole.subheadline)
                        
                        Text("Try Again")
                            .appFont(AppTextRole.subheadline.weight(.medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(Color.accentColor)
                    )
                }
                
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("Technical Details")
                            .appFont(AppTextRole.caption)
                        
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .appFont(AppTextRole.caption2)
                    }
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 32)
            
            // Technical details (collapsible)
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Error Details:")
                        .appFont(AppTextRole.caption.weight(.medium))
                        .foregroundColor(.secondary)
                    
                    Text(error.localizedDescription)
                        .appFont(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(uiColor: .tertiaryLabel))
                        .padding(12)
                        .background(Color.secondarySystemBackground)
                        .cornerRadius(8)
                }
                .padding(.horizontal, 32)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .animation(.easeInOut(duration: 0.3), value: isExpanded)
    }
    
    private var errorMessage: String {
        if error.localizedDescription.contains("network") || 
           error.localizedDescription.contains("connection") {
            return "Check your internet connection and try again"
        } else if error.localizedDescription.contains("timeout") {
            return "The request took too long. Please try again"
        } else if error.localizedDescription.contains("404") {
            return "The search service is temporarily unavailable"
        } else {
            return "Something went wrong. Please try again"
        }
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
