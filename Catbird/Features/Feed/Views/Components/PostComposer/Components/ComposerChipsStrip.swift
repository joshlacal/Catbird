//
//  ComposerChipsStrip.swift
//  Catbird
//

import SwiftUI
import Petrel

struct ComposerChipsStrip: View {
  let outlineTags: [String]
  let selectedLanguages: [LanguageCodeContainer]
  let selectedLabels: Set<ComAtprotoLabelDefs.LabelValue>
  let threadgateSettings: ThreadgateSettings
  let suggestedLanguage: LanguageCodeContainer?
  let hasText: Bool

  let onRemoveTag: (String) -> Void
  let onToggleLanguage: (LanguageCodeContainer) -> Void
  let onApplySuggestedLanguage: () -> Void
  let onEditThreadgate: () -> Void
  let onEditLabels: () -> Void

  static func isVisible(
    tagCount: Int,
    explicitLanguageCount: Int,
    labelCount: Int,
    threadgateIsCustom: Bool,
    hasLanguageSuggestion: Bool
  ) -> Bool {
    tagCount > 0 || explicitLanguageCount > 0 || labelCount > 0
      || threadgateIsCustom || hasLanguageSuggestion
  }

  private var threadgateIsCustom: Bool {
    !threadgateSettings.allowEverybody
  }

  private var showsLanguageSuggestion: Bool {
    guard let suggestedLanguage else { return false }
    return hasText && !selectedLanguages.contains(suggestedLanguage)
  }

  var body: some View {
    if Self.isVisible(
      tagCount: outlineTags.count,
      explicitLanguageCount: selectedLanguages.count,
      labelCount: selectedLabels.count,
      threadgateIsCustom: threadgateIsCustom,
      hasLanguageSuggestion: showsLanguageSuggestion
    ) {
      ScrollView(.horizontal) {
        HStack(spacing: 6) {
          ForEach(outlineTags, id: \.self) { tag in
            removableChip(text: "#\(tag)", accessibilityLabel: "Hashtag \(tag)") {
              onRemoveTag(tag)
            }
          }

          ForEach(selectedLanguages, id: \.self) { language in
            let displayName = Self.languageDisplayName(language)
            removableChip(text: displayName, accessibilityLabel: "Language \(displayName)") {
              onToggleLanguage(language)
            }
          }

          if threadgateIsCustom {
            let summary = Self.threadgateSummary(threadgateSettings)
            tappableChip(
              text: summary,
              systemImage: "bubble.left.and.exclamationmark.bubble.right",
              accessibilityLabel: "Who can reply: \(summary)",
              action: onEditThreadgate
            )
          }

          if !selectedLabels.isEmpty {
            let labelsText = "\(selectedLabels.count) label\(selectedLabels.count == 1 ? "" : "s")"
            tappableChip(
              text: labelsText,
              systemImage: "exclamationmark.triangle",
              accessibilityLabel: labelsText,
              action: onEditLabels
            )
          }

          if showsLanguageSuggestion, let suggestedLanguage {
            Button(action: onApplySuggestedLanguage) {
              HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                  .appFont(AppTextRole.caption2)
                Text("Detected: \(Self.languageDisplayName(suggestedLanguage))")
                  .appFont(AppTextRole.caption)
                  .fontWeight(.medium)
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(Color.accentColor.opacity(0.15))
              .foregroundStyle(Color.accentColor)
              .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Set language to \(Self.languageDisplayName(suggestedLanguage))")
          }
        }
        .padding(.horizontal, 1)
      }
      .scrollIndicators(.hidden)
    }
  }

  private func removableChip(
    text: String,
    accessibilityLabel: String,
    onRemove: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 4) {
      Text(text)
        .appFont(AppTextRole.caption)
        .fontWeight(.medium)
      Button(action: onRemove) {
        Image(systemName: "xmark.circle.fill")
          .appFont(AppTextRole.caption2)
          .foregroundStyle(.secondary)
          .padding(4)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Remove \(accessibilityLabel)")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Color.secondary.opacity(0.1))
    .foregroundStyle(.secondary)
    .clipShape(Capsule())
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityLabel)
  }

  private func tappableChip(
    text: String,
    systemImage: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: systemImage)
          .appFont(AppTextRole.caption2)
        Text(text)
          .appFont(AppTextRole.caption)
          .fontWeight(.medium)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Color.secondary.opacity(0.1))
      .foregroundStyle(.secondary)
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint("Opens the editor")
  }

  static func languageDisplayName(_ language: LanguageCodeContainer) -> String {
    Locale.current.localizedString(
      forLanguageCode: language.lang.languageCode?.identifier ?? ""
    ) ?? language.lang.minimalIdentifier
  }

  static func threadgateSummary(_ settings: ThreadgateSettings) -> String {
    if settings.allowEverybody { return "Anyone" }
    if settings.allowNobody { return "Nobody" }

    var parts: [String] = []
    if settings.allowMentioned { parts.append("Mentioned") }
    if settings.allowFollowing { parts.append("Following") }
    if settings.allowFollowers { parts.append("Followers") }
    if settings.allowLists { parts.append("Lists") }
    return parts.isEmpty ? "Custom" : parts.joined(separator: ", ")
  }
}
