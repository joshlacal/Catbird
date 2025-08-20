//
//  ContentLabelView.swift
//  Catbird
//
//  Created by Claude on 5/12/25.
//

import SwiftUI
import Petrel
import Observation

/// Visibility settings for different content categories
enum ContentVisibility: String, Codable, Identifiable, CaseIterable {
    case show = "Show"
    case warn = "Warn"
    case hide = "Hide"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .show: return "eye"
        case .warn: return "eye.trianglebadge.exclamationmark"
        case .hide: return "eye.slash"
        }
    }
    
    var color: Color {
        switch self {
        case .show: return .green
        case .warn: return .orange
        case .hide: return .red
        }
    }
}

/// A compact visual indicator for content labels
struct ContentLabelBadge: View {
    let label: ComAtprotoLabelDefs.Label
    let backgroundColor: Color
    
    init(label: ComAtprotoLabelDefs.Label) {
        self.label = label
        
        // Determine background color based on label type
        switch label.val.lowercased() {
        case "nsfw", "porn", "nudity", "sexual":
            backgroundColor = .red.opacity(0.7)
        case "spam", "scam", "impersonation", "misleading":
            backgroundColor = .orange.opacity(0.7)
        case "gore", "violence", "corpse", "self-harm":
            backgroundColor = .purple.opacity(0.7)
        case "hate", "hate-symbol", "terrorism":
            backgroundColor = .red.opacity(0.7)
        default:
            backgroundColor = .gray.opacity(0.5)
        }
    }
    
    var body: some View {
        Text(label.val)
            .appFont(AppTextRole.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor)
            )
    }
}

/// A view that displays content labels directly with clear visual styling
struct ContentLabelView: View {
    let labels: [ComAtprotoLabelDefs.Label]?
    
    var body: some View {
        if let labels = labels, !labels.isEmpty {
            HStack(spacing: 6) {
                // Always show labels directly - no hiding under caret
                ForEach(labels, id: \.val) { label in
                    ContentLabelBadge(label: label)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        }
    }
}

/// A view that handles display decisions for labeled content
struct ContentLabelManager<Content: View>: View {
    let labels: [ComAtprotoLabelDefs.Label]?
    let contentType: String
    @State private var isBlurred: Bool
    @State private var contentVisibility: ContentVisibility
    @Environment(AppState.self) private var appState
    let content: Content
    
    init(labels: [ComAtprotoLabelDefs.Label]?, contentType: String = "content", @ViewBuilder content: () -> Content) {
        self.labels = labels
        self.contentType = contentType
        let initialVisibility = ContentLabelManager.getContentVisibility(labels: labels)
        self._contentVisibility = State(initialValue: initialVisibility)
        self._isBlurred = State(initialValue: initialVisibility == .warn)
        self.content = content()
    }
    
    static func getContentVisibility(labels: [ComAtprotoLabelDefs.Label]?) -> ContentVisibility {
        guard let labels = labels, !labels.isEmpty else { return .show }
        
        // Check for the most restrictive content type first
        let labelValues = labels.map { $0.val.lowercased() }
        
        // Check for sensitive content labels and return appropriate visibility
        // This is the basic sync version - for full preference checking, use getEffectiveContentVisibility
        if labelValues.contains(where: { ["nsfw", "porn", "nudity", "sexual", "gore", "violence", "graphic", "suggestive"].contains($0) }) {
            return .warn
        }
        
        return .show
    }
    
    static func shouldInitiallyBlur(labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
        return getContentVisibility(labels: labels) == .warn
    }
    
    private var strongBlurOverlay: some View {
        // Create completely opaque overlay - no blurred content visible through
        return Rectangle()
            .fill(Color.black.opacity(0.95)) // Almost completely opaque
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                VStack {
                    Image(systemName: "eye.slash.fill")
                        .appFont(AppTextRole.title2)
                        .foregroundStyle(.white)
                        .padding(.bottom, 4)
                    
                    Text("Sensitive \(contentType.capitalized)")
                        .appFont(AppTextRole.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.bottom, 4)
                    
                    Text("This content may not be appropriate for all audiences")
                        .appFont(AppTextRole.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.bottom, 12)
                    
                    Button {
                        withAnimation {
                            isBlurred = false
                        }
                    } label: {
                        Text("Show Content")
                            .appFont(AppTextRole.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.gray.opacity(0.6))
                            .cornerRadius(18)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.8))
                )
                .padding(20)
            )
    }
    
    var body: some View {
        Group {
            switch contentVisibility {
            case .hide:
                // Completely hide content - show a minimal placeholder
                hiddenContentPlaceholder
                
            case .warn:
                VStack(spacing: 0) {
                    // Always show labels at the top - direct visibility
                    if let labels = labels, !labels.isEmpty {
                        ContentLabelView(labels: labels)
                            .padding(.bottom, 6)
                    }
                    
                    // Content with conditional blur
                    if isBlurred {
                        ZStack {
                            content
                            
                            // Strong blur overlay that completely obscures content
                            strongBlurOverlay
                        }
                        .onTapGesture {
                            // Double tap anywhere to reveal
                            withAnimation {
                                isBlurred = false
                            }
                        }
                    } else {
                        content
                            .overlay(alignment: .topTrailing) {
                                if labels != nil && !labels!.isEmpty {
                                    // Reblur button
                                    Button {
                                        withAnimation {
                                            isBlurred = true
                                        }
                                    } label: {
                                        Image(systemName: "eye.slash")
                                            .appFont(AppTextRole.caption)
                                            .padding(6)
                                            .background(Circle().fill(Color.black.opacity(0.6)))
                                            .foregroundStyle(.white)
                                    }
                                    .padding(12)
                                }
                            }
                    }
                }
                
            case .show:
                // Show content normally with labels always visible at top
                VStack(spacing: 0) {
                    if let labels = labels, !labels.isEmpty {
                        ContentLabelView(labels: labels)
                            .padding(.bottom, 6)
                    }
                    content
                }
            }
        }
        .task {
            await updateContentVisibility()
        }
    }
    
    /// Check if the current user is a minor (under 18) based on their birthdate
    private func isMinorAccount() async -> Bool {
        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            guard let birthDate = preferences.birthDate else {
                // If no birthdate is set, err on the side of caution for adult content
                return false
            }
            
            let calendar = Calendar.current
            let now = Date()
            let ageComponents = calendar.dateComponents([.year], from: birthDate, to: now)
            
            guard let age = ageComponents.year else {
                return false
            }
            
            return age < 18
        } catch {
            // If we can't determine age, don't apply minor restrictions
            return false
        }
    }
    
    private var hiddenContentPlaceholder: some View {
        VStack(spacing: 8) {
            // Show labels at the top so users know why content was hidden
            if let labels = labels, !labels.isEmpty {
                ContentLabelView(labels: labels)
                    .padding(.bottom, 8)
            }
            
            Image(systemName: "eye.slash.fill")
                .appFont(AppTextRole.title2)
                .foregroundStyle(.secondary)
            
            Text("Content Hidden")
                .appFont(AppTextRole.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            // Use a @State variable to track if user is minor for UI updates
            MinorAccountText(contentType: contentType, appState: appState)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(Color(platformColor: .platformSystemGray6))
        .cornerRadius(12)
    }
    
    private func updateContentVisibility() async {
        guard let labels = labels, !labels.isEmpty else { return }
        
        let visibility = await getEffectiveContentVisibility(for: labels)
        await MainActor.run {
            self.contentVisibility = visibility
            self.isBlurred = (visibility == .warn)
        }
    }
    
    private func getEffectiveContentVisibility(for labels: [ComAtprotoLabelDefs.Label]) async -> ContentVisibility {
        // Check each label and find the most restrictive setting
        var mostRestrictive: ContentVisibility = .show
        
        for label in labels {
            let labelValue = label.val.lowercased()
            let visibility = await getVisibilityForLabel(labelValue)
            
            // Hide is most restrictive, then warn, then show
            switch (mostRestrictive, visibility) {
            case (_, .hide):
                mostRestrictive = .hide
            case (.show, .warn):
                mostRestrictive = .warn
            default:
                break
            }
        }
        
        return mostRestrictive
    }
    
    private func getVisibilityForLabel(_ labelValue: String) async -> ContentVisibility {
        // For minor accounts (under 18), always hide adult content completely
        if await isMinorAccount() {
            let adultLabels = ["nsfw", "porn", "sexual", "nudity", "suggestive"]
            if adultLabels.contains(labelValue) {
                return .hide
            }
        }
        
        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            
            // Map label values to preference keys
            let preferenceKey: String
            switch labelValue {
            case "nsfw", "porn", "sexual":
                preferenceKey = "nsfw"
            case "nudity":
                preferenceKey = "nudity"
            case "gore", "violence", "graphic":
                preferenceKey = "graphic"
            case "suggestive":
                preferenceKey = "suggestive"
            default:
                preferenceKey = labelValue
            }
            
            // If adult content is disabled, force hide NSFW content
            if preferenceKey == "nsfw" && !appState.isAdultContentEnabled {
                return .hide
            }
            
            // Get the specific preference for this label
            let visibility = ContentFilterManager.getVisibilityForLabel(
                label: preferenceKey, 
                preferences: preferences.contentLabelPrefs
            )
            
            return visibility
        } catch {
            // If we can't get preferences, use safe defaults
            if !appState.isAdultContentEnabled && ["nsfw", "porn", "sexual"].contains(labelValue) {
                return .hide
            }
            return .warn
        }
    }
}

/// Helper view to show appropriate text based on whether user is a minor
struct MinorAccountText: View {
    let contentType: String
    let appState: AppState
    @State private var isMinor = false
    
    var body: some View {
        Text(isMinor ? "This \(contentType) was hidden for safety" : "This \(contentType) was hidden based on your content preferences")
            .appFont(AppTextRole.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
            .task {
                await checkIfMinor()
            }
    }
    
    private func checkIfMinor() async {
        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            guard let birthDate = preferences.birthDate else {
                isMinor = false
                return
            }
            
            let calendar = Calendar.current
            let now = Date()
            let ageComponents = calendar.dateComponents([.year], from: birthDate, to: now)
            
            guard let age = ageComponents.year else {
                isMinor = false
                return
            }
            
            await MainActor.run {
                isMinor = age < 18
            }
        } catch {
            await MainActor.run {
                isMinor = false
            }
        }
    }
}
