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
    case show = "ignore"  // AT Protocol uses "ignore" for showing content
    case warn = "warn"
    case hide = "hide"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .show: return "Show"
        case .warn: return "Warn"
        case .hide: return "Hide"
        }
    }
    
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
    
    /// Initialize from AT Protocol preference value
    init(fromPreference value: String) {
        switch value.lowercased() {
        case "ignore":
            self = .show
        case "warn":
            self = .warn
        case "hide":
            self = .hide
        default:
            self = .warn  // Default to warn for unknown values
        }
    }
    
    /// Convert to AT Protocol preference value
    var preferenceValue: String {
        switch self {
        case .show: return "ignore"
        case .warn: return "warn"
        case .hide: return "hide"
        }
    }
}

/// Helper function to get friendly label name
private func friendlyLabelName(_ labelKey: String) -> String {
    switch labelKey.lowercased() {
    case "nsfw", "porn":
        return "Adult Content"
    case "sexual":
        return "Sexual Content"
    case "suggestive":
        return "Sexually Suggestive"
    case "graphic", "gore":
        return "Graphic Content"
    case "violence":
        return "Violence"
    case "nudity":
        return "Non-Sexual Nudity"
    case "spam":
        return "Spam"
    case "misleading":
        return "Misleading"
    case "misinfo":
        return "Misinformation"
    case "hate":
        return "Hateful Content"
    case "harassment":
        return "Harassment"
    case "self-harm":
        return "Self-Harm"
    case "intolerant":
        return "Intolerance"
    default:
        // Capitalize and replace hyphens/underscores with spaces
        return labelKey.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}

/// A compact visual indicator for content labels
struct ContentLabelBadge: View {
    let label: ComAtprotoLabelDefs.Label
    let backgroundColor: Color
    let displayName: String
    
    init(label: ComAtprotoLabelDefs.Label) {
        self.label = label
        self.displayName = friendlyLabelName(label.val)
        
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
        Text(displayName)
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
    
    /// Determines if a label should be displayed as a badge
    /// Only show moderation labels, not informational ones
    private func shouldDisplayLabel(_ label: ComAtprotoLabelDefs.Label) -> Bool {
        let value = label.val.lowercased()
        
        // Skip informational labels
        let informationalLabels = [
            "bot-account",
            "!hide",
            "!warn",
            "!no-promote",
            "!no-unauthenticated"
        ]
        
        if informationalLabels.contains(value) {
            return false
        }
        
        // Only show moderation/content warning labels
        let moderationLabels = [
            "nsfw", "porn", "sexual", "nudity", "suggestive",
            "gore", "violence", "graphic", "graphic-media", "corpse", "self-harm",
            "hate", "hate-symbol", "terrorism",
            "spam", "scam", "impersonation", "misleading"
        ]
        
        return moderationLabels.contains(value)
    }
    
    var body: some View {
        if let labels = labels, !labels.isEmpty {
            // Filter labels to only show moderation-related ones
            let displayLabels = labels.filter { shouldDisplayLabel($0) }
            
            if !displayLabels.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        ForEach(displayLabels, id: \.val) { label in
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
}

struct ContentLabels {
    // Content-warning labels that should influence visibility (blur/hide)
     static let adultContentLabels: Set<String> = ["nsfw", "porn", "sexual"]
     static let warningContentLabels: Set<String> = ["nudity", "gore", "violence", "graphic", "graphic-media", "corpse", "self-harm", "suggestive"]
     static let contentWarningLabels: Set<String> = adultContentLabels.union(warningContentLabels)
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
        let labelValues = labels.map { $0.val.lowercased() }.filter { ContentLabels.contentWarningLabels.contains($0) }

        // Ignore labels that are not content warnings
        guard !labelValues.isEmpty else { return .show }

        // Check for sensitive content labels - be conservative and hide adult content initially
        if labelValues.contains(where: { ContentLabels.adultContentLabels.contains($0) }) {
            return .hide // Conservative default - will be updated by async task if user has adult content enabled
        }

        if labelValues.contains(where: { ContentLabels.warningContentLabels.contains($0) }) {
            return .warn
        }

        return .show
    }

    /// Legacy method - kept for compatibility but prefer getInitialContentVisibility for new code
    static func getContentVisibility(labels: [ComAtprotoLabelDefs.Label]?) -> ContentVisibility {
        guard let labels = labels, !labels.isEmpty else { return .show }

        // Check for the most restrictive content type first
        let labelValues = labels.map { $0.val.lowercased() }.filter { ContentLabels.contentWarningLabels.contains($0) }

        // No warning-eligible labels present
        guard !labelValues.isEmpty else { return .show }

        // Check for sensitive content labels and return appropriate visibility
        // This is the basic sync version - for full preference checking, use getEffectiveContentVisibility
        if labelValues.contains(where: { ContentLabels.contentWarningLabels.contains($0) }) {
            return .warn
        }

        return .show
    }
    
    static func shouldInitiallyBlur(labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
        return getInitialContentVisibility(labels: labels) == .warn
    }
    
    /// Generate a friendly title for the warning
    private var warningTitle: String {
        guard let labels = labels, !labels.isEmpty else {
            return "Sensitive Content"
        }
        
        // If single label, use its friendly name
        if labels.count == 1 {
            return friendlyLabelName(labels[0].val)
        }
        
        // Multiple labels - use generic title
        return "Sensitive Content"
    }
    
    /// Generate a comma-separated list of friendly label names for warning text
    private var warningLabels: String {
        var allLabels: [String] = []
        
        if let labels = labels {
            allLabels.append(contentsOf: labels.map { friendlyLabelName($0.val) })
        }
        
        if let selfLabelValues = selfLabelValues {
            allLabels.append(contentsOf: selfLabelValues.map { friendlyLabelName($0) })
        }
        
        guard !allLabels.isEmpty else {
            return "sensitive material"
        }
        
        // Deduplicate
        let uniqueLabels = Array(Set(allLabels)).sorted()
        
        if uniqueLabels.count == 1 {
            return uniqueLabels[0].lowercased()
        } else if uniqueLabels.count == 2 {
            return uniqueLabels.joined(separator: " and ").lowercased()
        } else {
            let last = uniqueLabels.last!
            let rest = uniqueLabels.dropLast().joined(separator: ", ")
            return "\(rest), and \(last)".lowercased()
        }
    }
    
    private var strongBlurOverlay: some View {
        // Create adaptive overlay that respects parent constraints
        GeometryReader { geometry in
            let isCompact = geometry.size.height < 200
            let outerPadding: CGFloat = isCompact ? 8 : 20
            let innerPadding: CGFloat = isCompact ? 8 : 16
            let iconBottomPadding: CGFloat = isCompact ? 2 : 4
            let textBottomPadding: CGFloat = isCompact ? 2 : 4
            let buttonBottomPadding: CGFloat = isCompact ? 8 : 12
            
            Rectangle()
                .fill(Color.black.opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    VStack(spacing: 0) {
                        Image(systemName: "eye.slash.fill")
                            .appFont(isCompact ? AppTextRole.body : AppTextRole.title2)
                            .foregroundStyle(.white)
                            .padding(.bottom, iconBottomPadding)
                        
                        Text(warningTitle)
                            .appFont(isCompact ? AppTextRole.caption : AppTextRole.subheadline)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.bottom, textBottomPadding)
                        
                        if !isCompact {
                            Text("May contain \(warningLabels)")
                                .appFont(AppTextRole.caption)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.bottom, buttonBottomPadding)
                        }
                        
                        Button {
                            withAnimation {
                                isBlurred = false
                            }
                        } label: {
                            Text("Show Content")
                                .appFont(isCompact ? AppTextRole.caption2 : AppTextRole.footnote)
                                .foregroundStyle(.white)
                                .padding(.horizontal, isCompact ? 12 : 16)
                                .padding(.vertical, isCompact ? 6 : 8)
                                .background(Color.gray.opacity(0.6))
                                .cornerRadius(isCompact ? 14 : 18)
                        }
                    }
                    .padding(innerPadding)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.8))
                    )
                    .padding(outerPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                )
        }
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
        let visibleLabels = labels.filter { ContentLabels.contentWarningLabels.contains($0.val.lowercased()) }
        let visibleSelfLabels = selfLabelValues.filter { ContentLabels.contentWarningLabels.contains($0.lowercased()) }

        // If no warning-eligible labels exist, show content normally
        if visibleLabels.isEmpty && visibleSelfLabels.isEmpty {
            return .show
        }

        // Check each label and find the most restrictive setting
        var mostRestrictive: ContentVisibility = .show

        // Evaluate canonical labels
        for label in visibleLabels {
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
        for value in visibleSelfLabels {
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
        let normalizedValue = label.val.lowercased()

        // Skip labels that are not content warnings
        guard ContentLabels.contentWarningLabels.contains(normalizedValue) else {
            return .show
        }

        do {
            let preferences = try await appState.preferencesManager.getPreferences()

            // Map label values to preference keys
            let preferenceKey: String
            switch normalizedValue {
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
        let normalizedValue = value.lowercased()

        // Skip labels that are not content warnings
        guard ContentLabels.contentWarningLabels.contains(normalizedValue) else {
            return .show
        }

        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            // Map value to preference key
            let preferenceKey: String
            switch normalizedValue {
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
