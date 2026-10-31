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

/// Remembers content-warning decisions outside of any one view instance.
///
/// Feed and thread rows are SwiftUI views hosted in reused collection view cells,
/// so `@State` inside `ContentLabelManager` is thrown away whenever a cell is
/// reused, and re-created views start from the conservative initial visibility
/// until the async preference lookup finishes. Both change the row's height after
/// it has been laid out, which shows up as the post re-rendering and the feed
/// jumping. Keeping the user's reveal choice and the last resolved visibility here
/// lets a re-created view lay out at its final height on the first pass.
@MainActor
final class ContentLabelDecisionStore {
    static let shared = ContentLabelDecisionStore()

    private static let maxEntries = 5_000

    private var revealedKeys: Set<String> = []
    private var resolvedVisibility: [String: ContentVisibility] = [:]

    func isRevealed(_ key: String?) -> Bool {
        guard let key else { return false }
        return revealedKeys.contains(key)
    }

    func setRevealed(_ revealed: Bool, for key: String?) {
        guard let key else { return }
        if revealed {
            if revealedKeys.count >= Self.maxEntries { revealedKeys.removeAll() }
            revealedKeys.insert(key)
        } else {
            revealedKeys.remove(key)
        }
    }

    func visibility(for key: String) -> ContentVisibility? {
        resolvedVisibility[key]
    }

    func setVisibility(_ visibility: ContentVisibility, for key: String) {
        if resolvedVisibility.count >= Self.maxEntries { resolvedVisibility.removeAll() }
        resolvedVisibility[key] = visibility
    }
}

/// A view that handles display decisions for labeled content
struct ContentLabelManager<Content: View>: View {

    let labels: [ComAtprotoLabelDefs.Label]?
    // Optional: additional self-applied label values (e.g., from record selfLabels)
    // Used only for visibility decisions; not displayed as badges.
    let selfLabelValues: [String]?
    let contentType: String
    /// Visibility resolved from the user's preferences, tagged with the key it was
    /// resolved for so a stale result is ignored if the labels change.
    @State private var resolved: ResolvedVisibility?
    /// Reveal/re-blur done in this view instance. The shared store carries the
    /// choice across cell reuse; this drives the immediate re-render.
    @State private var localRevealOverride: Bool?
    @State private var isCollapsed = false
    @Environment(AppState.self) private var appState
    @Environment(\.postID) private var postID
    let content: Content

    private struct ResolvedVisibility {
        let key: String
        let visibility: ContentVisibility
    }

    private var decisions: ContentLabelDecisionStore { .shared }

    init(labels: [ComAtprotoLabelDefs.Label]?, selfLabelValues: [String]? = nil, contentType: String = "content", @ViewBuilder content: () -> Content) {
        self.labels = labels
        self.selfLabelValues = selfLabelValues
        self.contentType = contentType
        self.content = content()
    }

    /// Identifies this label set for this account, so a cached visibility is never
    /// reused under another account's moderation preferences.
    private var visibilityKey: String {
        let labelParts = (labels ?? []).map { "\($0.src.didString())|\($0.val.lowercased())" }.sorted()
        let selfParts = (selfLabelValues ?? []).map { "self|\($0.lowercased())" }.sorted()
        return ([appState.userDID ?? ""] + labelParts + selfParts).joined(separator: ",")
    }

    /// Identifies the labeled subject (the post or quoted record) so a reveal
    /// survives cell reuse and also applies where the same post appears again.
    private var revealKey: String? {
        if let subject = labels?.first?.uri.uriString() {
            return "\(contentType)|\(subject)"
        }
        if !postID.isEmpty {
            return "\(contentType)|\(postID)"
        }
        return nil
    }

    /// Best visibility known right now: the result resolved for these labels, else
    /// the last result for the same labels and account, else the conservative default.
    private var contentVisibility: ContentVisibility {
        if isCollapsed { return .hide }
        let key = visibilityKey
        if let resolved, resolved.key == key { return resolved.visibility }
        if let cached = decisions.visibility(for: key) { return cached }
        return Self.getInitialContentVisibility(labels: labels)
    }

    private var isRevealed: Bool {
        localRevealOverride ?? decisions.isRevealed(revealKey)
    }

    private var isBlurred: Bool {
        contentVisibility == .warn && !isRevealed
    }

    /// Changes reveal state without animation. The row lives in a self-sizing
    /// collection view cell, which resizes immediately; animating the SwiftUI side
    /// makes the whole post slide inside the already-resized cell.
    private func setRevealed(_ revealed: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            localRevealOverride = revealed
        }
        decisions.setRevealed(revealed, for: revealKey)
    }

    private func collapse() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            localRevealOverride = false
            isCollapsed = true
        }
        decisions.setRevealed(false, for: revealKey)
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
        Rectangle()
            .fill(Color.black.opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                VStack(spacing: 0) {
                    Image(systemName: "eye.slash.fill")
                        .appFont(AppTextRole.title2)
                        .foregroundStyle(.white)
                        .padding(.bottom, 4)

                    Text(warningTitle)
                        .appFont(AppTextRole.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.bottom, 4)

                    Text("May contain \(warningLabels)")
                        .appFont(AppTextRole.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.bottom, 12)

                    Button {
                        setRevealed(true)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            // Placeholder instead of actual content to avoid rendering videos/GIFs under overlay
                            Rectangle()
                                .fill(Color(platformColor: .platformSystemGray6))
                                .frame(minHeight: 200)

                            strongBlurOverlay
                        }
                        .onTapGesture {
                            setRevealed(true)
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
                                                setRevealed(false)
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
                                            collapse()
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
        .task(id: visibilityKey) {
            // Resolve against the user's preferences. This no longer touches the
            // reveal state, so re-appearing does not re-blur revealed content.
            await updateContentVisibility()
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
        let key = visibilityKey
        // Consider both canonical labels and any self-applied label values
        let visibility = await getEffectiveContentVisibility(for: labels ?? [], selfLabelValues: selfLabelValues ?? [])
        await MainActor.run {
            decisions.setVisibility(visibility, for: key)
            // Only write state when the answer changes, so an unchanged result
            // does not invalidate the row and re-measure the cell.
            if resolved?.key != key || resolved?.visibility != visibility {
                resolved = ResolvedVisibility(key: key, visibility: visibility)
            }
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
