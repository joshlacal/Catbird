//
//  DetectedQueryLanguagesAdmonition.swift
//  Catbird
//
//  Admonition tip banner for detected query languages in search (G08).
//

import SwiftUI

/// Admonition tip banner displaying detected query languages returned by searchPostsV2 (G08).
/// Allows the user to tap a detected language to filter post search results.
public struct DetectedQueryLanguagesAdmonition: View {
  public let detectedLanguages: [String]
  public let onSelectLanguage: (String) -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(AppState.self) private var appState

  public init(
    detectedLanguages: [String],
    onSelectLanguage: @escaping (String) -> Void
  ) {
    self.detectedLanguages = detectedLanguages
    self.onSelectLanguage = onSelectLanguage
  }

  /// Converts a BCP-47 or ISO language code to a localized display name using the specified or current Locale.
  public static func localizedLanguageName(for code: String, locale: Locale = .current) -> String {
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if let name = locale.localizedString(forLanguageCode: trimmed) {
      return name
    }
    if let name = locale.localizedString(forIdentifier: trimmed) {
      return name
    }
    return trimmed.uppercased()
  }

  /// Returns unselected detected languages, filtering out any currently selected language.
  public static func unselectedLanguages(
    from detectedLanguages: [String],
    selectedLanguage: String?
  ) -> [String] {
    guard let selected = selectedLanguage?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !selected.isEmpty else {
      return detectedLanguages
    }
    return detectedLanguages.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != selected }
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
      HStack(spacing: 6) {
        Image(systemName: "character.bubble")
          .font(.subheadline)
          .foregroundColor(.accentColor)

        Text("Filter by detected language")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.primary)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(detectedLanguages, id: \.self) { langCode in
            Button {
              onSelectLanguage(langCode)
            } label: {
              HStack(spacing: 4) {
                Image(systemName: "globe")
                  .font(.caption2)
                Text(Self.localizedLanguageName(for: langCode))
                  .appFont(AppTextRole.caption)
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(Color.accentColor.opacity(0.12))
              .foregroundColor(.accentColor)
              .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filter by \(Self.localizedLanguageName(for: langCode))")
          }
        }
        .padding(.vertical, 2)
      }
    }
    .padding(DesignTokens.Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: DesignTokens.Size.radiusMD)
        .fill(Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme))
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignTokens.Size.radiusMD)
        .stroke(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme), lineWidth: 0.5)
    )
    .padding(.horizontal)
    .padding(.vertical, DesignTokens.Spacing.xs)
  }
}
