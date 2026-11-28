//
//  CatbirdBadge.swift
//  Catbird
//
//  Tiny non-interactive capsule label backed by `CatbirdTone` and `@Environment(\.catbirdTheme)`.
//  Text badge or icon-only badge (which requires an accessibility label), never empty.
//

import SwiftUI

struct CatbirdBadge: View {
  private let text: Text?
  private let systemImage: String?
  private let accessibilityText: Text?
  var tone: CatbirdTone

  @Environment(\.catbirdTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast

  private var increased: Bool { theme.isHighContrast || contrast == .increased }

  init(_ text: LocalizedStringKey, systemImage: String? = nil, tone: CatbirdTone = .neutral) {
    self.init(Text(text), systemImage: systemImage, tone: tone)
  }

  init(_ text: Text, systemImage: String? = nil, tone: CatbirdTone = .neutral) {
    self.text = text
    self.systemImage = systemImage
    self.accessibilityText = nil
    self.tone = tone
  }

  /// Icon-only badge.
  init(
    systemImage: String, accessibilityLabel: LocalizedStringKey, tone: CatbirdTone = .neutral
  ) {
    self.text = nil
    self.systemImage = systemImage
    self.accessibilityText = Text(accessibilityLabel)
    self.tone = tone
  }

  var body: some View {
    let toneColor = tone.color(in: theme)
    HStack(spacing: Space.xs) {
      if let systemImage {
        Image(systemName: systemImage).accessibilityHidden(text != nil)
      }
      if let text {
        text.lineLimit(1)
      }
    }
    .appFont(AppTextRole.caption2.weight(.semibold))
    .foregroundStyle(toneColor)
    .padding(.horizontal, Space.sm)
    .padding(.vertical, Space.xs)
    .background(
      Capsule(style: .continuous)
        .fill(toneColor.opacity(increased ? 0.22 : 0.14))
    )
    .overlay {
      if increased {
        Capsule(style: .continuous)
          .strokeBorder(toneColor.opacity(0.4), lineWidth: 1)
      }
    }
    .modifier(BadgeAccessibility(label: accessibilityText))
  }
}

private struct BadgeAccessibility: ViewModifier {
  let label: Text?

  @ViewBuilder func body(content: Content) -> some View {
    if let label {
      content.accessibilityElement(children: .ignore).accessibilityLabel(label)
    } else {
      content
    }
  }
}

#Preview("Badges") {
  HStack {
    CatbirdBadge(Text(verbatim: "New"), tone: .accent)
    CatbirdBadge(Text(verbatim: "Muted"), systemImage: "speaker.slash")
    CatbirdBadge(Text(verbatim: "Verified"), systemImage: "checkmark", tone: .success)
    CatbirdBadge(Text(verbatim: "Beta"), tone: .warning)
    CatbirdBadge(Text(verbatim: "Blocked"), tone: .danger)
  }
  .padding(Space.screenMargin)
}
