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
  let interactionSettings: PostInteractionSettingsState
  let suggestedLanguage: LanguageCodeContainer?
  let hasText: Bool

  let onRemoveTag: (String) -> Void
  let onToggleLanguage: (LanguageCodeContainer) -> Void
  let onApplySuggestedLanguage: () -> Void
  let onEditInteractionSettings: () -> Void
  let onEditLabels: () -> Void
  /// Reply settings only apply to the first post of a thread, so replies hide them.
  let showsInteractionSettings: Bool
  @Environment(\.locale) private var locale

  init(
    outlineTags: [String],
    selectedLanguages: [LanguageCodeContainer],
    selectedLabels: Set<ComAtprotoLabelDefs.LabelValue>,
    interactionSettings: PostInteractionSettingsState,
    suggestedLanguage: LanguageCodeContainer?,
    hasText: Bool,
    onRemoveTag: @escaping (String) -> Void,
    onToggleLanguage: @escaping (LanguageCodeContainer) -> Void,
    onApplySuggestedLanguage: @escaping () -> Void,
    onEditInteractionSettings: @escaping () -> Void,
    onEditLabels: @escaping () -> Void,
    showsInteractionSettings: Bool = true
  ) {
    self.outlineTags = outlineTags
    self.selectedLanguages = selectedLanguages
    self.selectedLabels = selectedLabels
    self.interactionSettings = interactionSettings
    self.suggestedLanguage = suggestedLanguage
    self.hasText = hasText
    self.onRemoveTag = onRemoveTag
    self.onToggleLanguage = onToggleLanguage
    self.onApplySuggestedLanguage = onApplySuggestedLanguage
    self.onEditInteractionSettings = onEditInteractionSettings
    self.onEditLabels = onEditLabels
    self.showsInteractionSettings = showsInteractionSettings
  }

  init(
    outlineTags: [String],
    selectedLanguages: [LanguageCodeContainer],
    selectedLabels: Set<ComAtprotoLabelDefs.LabelValue>,
    threadgateSettings: ThreadgateSettings,
    suggestedLanguage: LanguageCodeContainer?,
    hasText: Bool,
    onRemoveTag: @escaping (String) -> Void,
    onToggleLanguage: @escaping (LanguageCodeContainer) -> Void,
    onApplySuggestedLanguage: @escaping () -> Void,
    onEditThreadgate: @escaping () -> Void,
    onEditLabels: @escaping () -> Void
  ) {
    self.init(
      outlineTags: outlineTags,
      selectedLanguages: selectedLanguages,
      selectedLabels: selectedLabels,
      interactionSettings: PostInteractionSettingsState(threadgate: threadgateSettings, allowQuotes: true),
      suggestedLanguage: suggestedLanguage,
      hasText: hasText,
      onRemoveTag: onRemoveTag,
      onToggleLanguage: onToggleLanguage,
      onApplySuggestedLanguage: onApplySuggestedLanguage,
      onEditInteractionSettings: onEditThreadgate,
      onEditLabels: onEditLabels
    )
  }
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

  private var interactionSettingsIsCustom: Bool {
    showsInteractionSettings && interactionSettings.isCustom
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
      threadgateIsCustom: interactionSettingsIsCustom,
      hasLanguageSuggestion: showsLanguageSuggestion
    ) {
      ScrollView(.horizontal) {
        HStack(spacing: 6) {
          ForEach(outlineTags, id: \.self) { tag in
            removableChip(
              text: "#\(tag)",
              accessibilityLabel: String(localized: "Hashtag \(tag)", comment: "Accessibility label for hashtag chip in post composer")
            ) {
              onRemoveTag(tag)
            }
          }

          ForEach(selectedLanguages, id: \.self) { language in
            let displayName = Self.languageDisplayName(language, locale: locale)
            removableChip(
              text: displayName,
              accessibilityLabel: String(localized: "Language \(displayName)", comment: "Accessibility label for selected language chip in post composer")
            ) {
              onToggleLanguage(language)
            }
          }

          if interactionSettingsIsCustom {
            let summary = interactionSettings.summary
            tappableChip(
              text: summary,
              systemImage: "bubble.left.and.bubble.right",
              accessibilityLabel: String(localized: "Interaction settings: \(summary)", comment: "Accessibility label for reply and quote settings chip in post composer"),
              action: onEditInteractionSettings
            )
          }

          if !selectedLabels.isEmpty {
            let labelsText = String(
              localized: "\(selectedLabels.count) labels",
              comment: "Chip showing number of content warning labels selected on a post"
            )
            tappableChip(
              text: labelsText,
              systemImage: "exclamationmark.triangle",
              accessibilityLabel: labelsText,
              action: onEditLabels
            )
          }

          if showsLanguageSuggestion, let suggestedLanguage {
            let suggestedDisplayName = Self.languageDisplayName(suggestedLanguage, locale: locale)
            Button(action: onApplySuggestedLanguage) {
              HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                  .appFont(AppTextRole.caption2)
                Text("Detected: \(suggestedDisplayName)", comment: "Suggested post language chip; variable is localized language name")
                  .appFont(AppTextRole.caption)
                  .fontWeight(.medium)
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(Color.accentColor.opacity(0.15))
              .background(.regularMaterial, in: Capsule())
              .foregroundStyle(Color.accentColor)
              .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Set language to \(suggestedDisplayName)", comment: "Accessibility label for suggested post language chip"))
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
          .contentShape(Rectangle().inset(by: -6))
      }
      .accessibilityLabel(Text("Remove \(accessibilityLabel)", comment: "Accessibility label for button that removes a composer chip"))
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(.regularMaterial, in: Capsule())
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
      .background(.regularMaterial, in: Capsule())
      .foregroundStyle(.secondary)
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint("Opens the editor")
  }

  static func languageDisplayName(_ language: LanguageCodeContainer, locale: Locale = .current) -> String {
    locale.localizedString(
      forLanguageCode: language.lang.languageCode?.identifier ?? ""
    ) ?? language.lang.minimalIdentifier
  }

  static func threadgateSummary(_ settings: ThreadgateSettings) -> String {
    if settings.allowEverybody {
      return String(localized: "Anyone", comment: "Reply restriction summary allowing everyone to reply")
    }
    if settings.allowNobody {
      return String(localized: "Nobody", comment: "Reply restriction summary disabling replies")
    }

    var parts: [String] = []
    if settings.allowMentioned {
      parts.append(String(localized: "Mentioned", comment: "Reply restriction summary item for mentioned users"))
    }
    if settings.allowFollowing {
      parts.append(String(localized: "Following", comment: "Reply restriction summary item for accounts the author follows"))
    }
    if settings.allowFollowers {
      parts.append(String(localized: "Followers", comment: "Reply restriction summary item for the author's followers"))
    }
    if settings.allowLists {
      parts.append(String(localized: "Lists", comment: "Reply restriction summary item for selected user lists"))
    }
    return parts.isEmpty
      ? String(localized: "Custom", comment: "Reply restriction summary when custom rules apply")
      : parts.joined(separator: ", ")
  }
}
