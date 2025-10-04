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
            VStack(alignment: .leading, spacing: 0) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A view that handles display decisions for labeled content
struct ContentLabelManager<Content: View>: View {
    let labels: [ComAtprotoLabelDefs.Label]?
    // Optional: additional self-applied label values (e.g., from record selfLabels)
    // Used only for visibility decisions; not displayed as badges.
    let selfLabelValues: [String]?
    let contentType: String
    @State private var isBlurred: Bool
    @State private var contentVisibility: ContentVisibility
    @Environment(AppState.self) private var appState
    let content: Content
    
    init(labels: [ComAtprotoLabelDefs.Label]?, selfLabelValues: [String]? = nil, contentType: String = "content", @ViewBuilder content: () -> Content) {
        self.labels = labels
        self.selfLabelValues = selfLabelValues
        self.contentType = contentType
        // Use a more conservative initial visibility that will be updated by async task
        let initialVisibility = ContentLabelManager.getInitialContentVisibility(labels: labels)
        self._contentVisibility = State(initialValue: initialVisibility)
        self._isBlurred = State(initialValue: initialVisibility == .warn)
        self.content = content()
    }
    
    /// Conservative initial visibility determination without user preferences
    /// This is used before async preference loading completes
    static func getInitialContentVisibility(labels: [ComAtprotoLabelDefs.Label]?) -> ContentVisibility {
        guard let labels = labels, !labels.isEmpty else { return .show }

        // Check for the most restrictive content type first
        let labelValues = labels.map { $0.val.lowercased() }

        // Check for sensitive content labels - be conservative and hide adult content initially
        if labelValues.contains(where: { ["nsfw", "porn", "sexual"].contains($0) }) {
            return .hide // Conservative default - will be updated by async task if user has adult content enabled
        }

        if labelValues.contains(where: { ["nudity", "gore", "violence", "graphic", "suggestive"].contains($0) }) {
            return .warn
        }

        return .show
    }

    /// Legacy method - kept for compatibility but prefer getInitialContentVisibility for new code
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
        return getInitialContentVisibility(labels: labels) == .warn
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
                VStack(alignment: .leading, spacing: 6) {
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
                        // When revealed under warn, allow collapsing again to a compact placeholder
                        VStack(alignment: .leading, spacing: 6) {
                            content
                                .overlay(alignment: .topTrailing) {
                                    HStack(spacing: 8) {
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
                                        }
                                        // Collapse button
                                        Button {
                                            withAnimation {
                                                contentVisibility = .hide
                                            }
                                        } label: {
                                            HStack(spacing: 6) {
                                                Image(systemName: "chevron.up.square")
                                                Text("Collapse")
                                            }
                                            .appFont(AppTextRole.caption)
                                            .padding(6)
                                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.6)))
                                            .foregroundStyle(.white)
                                        }
                                    }
                                    .padding(12)
                                }
                        }
                    }
                }
                
            case .show:
                // Show content normally with labels always visible at top
                VStack(alignment: .leading, spacing: 6) {
                    if let labels = labels, !labels.isEmpty {
                        ContentLabelView(labels: labels)
                            .padding(.bottom, 6)
                    }
                    content
                }
            }
        }
        .task {
            // Update visibility immediately when view appears
            await updateContentVisibility()
        }
        .onAppear {
            // Also update when view appears (in case task doesn't run immediately)
            Task {
                await updateContentVisibility()
            }
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
            SettingsHiddenText(contentType: contentType)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(Color(platformColor: .platformSystemGray6))
        .cornerRadius(12)
    }
    
    private func updateContentVisibility() async {
        // Consider both canonical labels and any self-applied label values
        let visibility = await getEffectiveContentVisibility(for: labels ?? [], selfLabelValues: selfLabelValues ?? [])
        await MainActor.run {
            self.contentVisibility = visibility
            self.isBlurred = (visibility == .warn)
        }
    }
    
    private func getEffectiveContentVisibility(for labels: [ComAtprotoLabelDefs.Label], selfLabelValues: [String]) async -> ContentVisibility {
        // Check each label and find the most restrictive setting
        var mostRestrictive: ContentVisibility = .show
        
        // Evaluate canonical labels
        for label in labels {
            let visibility = await getVisibilityForLabel(label)
            switch (mostRestrictive, visibility) {
            case (_, .hide):
                mostRestrictive = .hide
            case (.show, .warn):
                mostRestrictive = .warn
            default:
                break
            }
        }
        
        // Evaluate self-applied label values (no src)
        for value in selfLabelValues {
            let visibility = await getVisibilityForLabelValue(value)
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
    
    private func getVisibilityForLabel(_ label: ComAtprotoLabelDefs.Label) async -> ContentVisibility {
        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            
            // Map label values to preference keys
            let preferenceKey: String
            switch label.val.lowercased() {
            case "nsfw", "porn", "sexual":
                preferenceKey = "nsfw"
            case "nudity":
                preferenceKey = "nudity"
            case "gore", "violence", "graphic", "graphic-media":
                preferenceKey = "graphic"
            case "suggestive":
                preferenceKey = "suggestive"
            default:
                preferenceKey = label.val.lowercased()
            }
            
            // If adult content is disabled, force hide NSFW content
            if preferenceKey == "nsfw" && !appState.isAdultContentEnabled {
                return .hide
            }
            
            // Get specific preference, preferring labeler-scoped when available
            let visibility = ContentFilterManager.getVisibilityForLabel(
                label: preferenceKey,
                labelerDid: label.src,
                preferences: preferences.contentLabelPrefs)
            
            return visibility
        } catch {
            // If we can't get preferences, use safe defaults
            if !appState.isAdultContentEnabled && ["nsfw", "porn", "sexual"].contains(label.val.lowercased()) {
                return .hide
            }
            return .warn
        }
    }

    private func getVisibilityForLabelValue(_ value: String) async -> ContentVisibility {
        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            // Map value to preference key
            let preferenceKey: String
            switch value.lowercased() {
            case "nsfw", "porn", "sexual":
                preferenceKey = "nsfw"
            case "nudity":
                preferenceKey = "nudity"
            case "gore", "violence", "graphic", "graphic-media":
                preferenceKey = "graphic"
            case "suggestive":
                preferenceKey = "suggestive"
            default:
                preferenceKey = value.lowercased()
            }
            if preferenceKey == "nsfw" && !appState.isAdultContentEnabled { return .hide }
            let visibility = ContentFilterManager.getVisibilityForLabel(
                label: preferenceKey,
                labelerDid: nil,
                preferences: preferences.contentLabelPrefs
            )
            return visibility
        } catch {
            if !appState.isAdultContentEnabled && ["nsfw", "porn", "sexual"].contains(value.lowercased()) {
                return .hide
            }
            return .warn
        }
    }
}

// Helper text when content is hidden by settings
struct SettingsHiddenText: View {
    let contentType: String
    var body: some View {
        Text("This \(contentType) was hidden based on your content settings")
            .appFont(AppTextRole.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)
    }
}
