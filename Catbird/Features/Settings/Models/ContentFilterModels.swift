import Foundation
import SwiftUI
import Petrel

/// Represents a content category for filtering purposes
struct ContentCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let visibilityKey: String
    
    // Static definitions for known content categories
    static let adult = ContentCategory(
        id: "adult",
        name: "Adult Content",
        description: "Explicit sexual images, videos, text, or audio",
        visibilityKey: "nsfw"
    )
    
    static let suggestive = ContentCategory(
        id: "suggestive",
        name: "Sexually Suggestive",
        description: "Sexualized content that doesn't show explicit sexual activity",
        visibilityKey: "suggestive"
    )
    
    static let violent = ContentCategory(
        id: "violent",
        name: "Graphic Content",
        description: "Images, videos, or text describing violence, blood, or injury",
        visibilityKey: "graphic"
    )
    
    static let nudity = ContentCategory(
        id: "nudity",
        name: "Non-Sexual Nudity",
        description: "Artistic, educational, or non-sexualized images of nudity",
        visibilityKey: "nudity"
    )
    
    static let allCategories: [ContentCategory] = [
        .adult,
        .suggestive,
        .violent,
        .nudity
    ]
}

/// Manages the content filter settings and provides interactions with server preferences
class ContentFilterManager {
    /// Convert content label preferences from the server model to our display model
    static func getVisibilityForLabel(label: String, preferences: [ContentLabelPreference]) -> ContentVisibility {
        // Look for a specific preference for this label
        if let pref = preferences.first(where: { $0.label == label }) {
            return ContentVisibility(rawValue: pref.visibility) ?? .warn
        }

        // Default to warn if no specific preference
        return .warn
    }
    
    /// Get visibility for a label considering only user preferences (no age gating in this client)
    @MainActor
    static func getPolicyVisibility(
        label: String,
        preferences: [ContentLabelPreference]
    ) -> ContentVisibility {
        return getVisibilityForLabel(label: label, preferences: preferences)
    }

    /// Resolve visibility for a label with an optional labeler scope.
    /// If a labeler-specific preference exists, it takes precedence; otherwise fall back to global.
    static func getVisibilityForLabel(label: String, labelerDid: DID?, preferences: [ContentLabelPreference]) -> ContentVisibility {
        // Prefer labeler-scoped preference when available
        if let did = labelerDid?.didString(),
           let scoped = preferences.first(where: { $0.label == label && $0.labelerDid?.didString() == did }) {
            return ContentVisibility(rawValue: scoped.visibility) ?? .warn
        }

        // Fall back to global (no labeler) preference
        if let global = preferences.first(where: { $0.label == label && $0.labelerDid == nil }) {
            return ContentVisibility(rawValue: global.visibility) ?? .warn
        }

        // Last fallback: any match for this label
        return getVisibilityForLabel(label: label, preferences: preferences)
    }

    /// Convert our display model to the server model format
    static func createPreferenceForLabel(label: String, visibility: ContentVisibility) -> ContentLabelPreference {
        return ContentLabelPreference(
            labelerDid: nil,
            label: label,
            visibility: visibility.rawValue
        )
    }

    /// Check if adult content is enabled by checking both server preferences and app state
    static func isAdultContentEnabled(appState: AppState) -> Bool {
        // First check the app state (which should be synced with server preferences)
        return appState.isAdultContentEnabled
    }

    /// Update content label preferences on the server via PreferencesManager
    static func updateContentLabelPreferences(
        appState: AppState,
        contentLabels: [ContentLabelPreference]
    ) async throws {
        try await appState.preferencesManager.updateContentLabelPreferences(contentLabels)
    }

    /// Get the effective content visibility for a label type, considering age restrictions and preferences
    static func getEffectiveVisibility(
        label: String,
        appState: AppState
    ) async -> ContentVisibility {
        do {
            // Get the server preferences
            let preferences = try await appState.preferencesManager.getPreferences()
            
            // Use user preference visibility only
            let visibility = await getPolicyVisibility(
                label: label,
                preferences: preferences.contentLabelPrefs
            )

            // Additional check: if adult content is globally disabled, force hide nsfw content
            if label == "nsfw" && !appState.isAdultContentEnabled {
                return .hide
            }

            return visibility
        } catch {
            // If we can't get server preferences, use safe defaults
            if label == "nsfw" {
                if !appState.isAdultContentEnabled {
                    return .hide
                }
            }
            return .warn
        }
    }
}

/// A three-state selector for content visibility options
struct ContentVisibilitySelector: View {
    let title: String
    let description: String
    @Binding var selection: ContentVisibility
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .appFont(AppTextRole.headline)
            
            Text(description)
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
            
            Picker("Content Visibility", selection: $selection) {
                ForEach(ContentVisibility.allCases, id: \.id) { option in
                    Image(systemName: option.iconName)
                        .foregroundStyle(option.color)
                        .appFont(size: 20)
                        .tag(option)
                        .help(option.rawValue) // Accessibility label
                }
            }
            .pickerStyle(.segmented)
            .padding(.top, 4)
            
            // Icon legend
            HStack(spacing: 20) {
                ForEach(ContentVisibility.allCases, id: \.id) { option in
                    HStack(spacing: 4) {
                        Image(systemName: option.iconName)
                            .foregroundStyle(option.color)
                            .appFont(AppTextRole.caption)
                        Text(option.rawValue)
                            .appFont(AppTextRole.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }
}
