//
//  CatbirdBadge.swift
//  Catbird
//
//  Tiny non-interactive capsule label. Text badge or icon-only badge (which
//  requires an accessibility label), never empty.
//

import SwiftUI

enum CatbirdBadgeTone: CaseIterable, Sendable {
  case neutral, accent, success, warning, danger

  var color: Color {
    switch self {
    case .neutral: return .secondary
    case .accent: return .accentColor
    case .success: return .green
    case .warning: return .orange
    case .danger: return .red
    }
  }
}

struct CatbirdBadge: View {
  private let text: Text?
  private let systemImage: String?
  private let accessibilityText: Text?
  var tone: CatbirdBadgeTone

  init(_ text: LocalizedStringKey, systemImage: String? = nil, tone: CatbirdBadgeTone = .neutral) {
    self.init(Text(text), systemImage: systemImage, tone: tone)
  }

  init(_ text: Text, systemImage: String? = nil, tone: CatbirdBadgeTone = .neutral) {
    self.text = text
    self.systemImage = systemImage
    self.accessibilityText = nil
    self.tone = tone
  }

  /// Icon-only badge.
  init(
    systemImage: String, accessibilityLabel: LocalizedStringKey, tone: CatbirdBadgeTone = .neutral
  ) {
    self.text = nil
    self.systemImage = systemImage
    self.accessibilityText = Text(accessibilityLabel)
    self.tone = tone
  }

  var body: some View {
    HStack(spacing: Space.xs) {
      if let systemImage {
        Image(systemName: systemImage).accessibilityHidden(text != nil)
      }
      if let text {
        text.lineLimit(1)
      }
    }
    .appFont(AppTextRole.caption2)
    .fontWeight(.semibold)
    .foregroundStyle(tone.color)
    .padding(.horizontal, Space.sm)
    .padding(.vertical, Space.xs)
    .background(Capsule(style: .continuous).fill(tone.color.opacity(0.14)))
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
