//
//  CatbirdCard.swift
//  Catbird
//
//  Card chrome. `.embed` is exactly the tuned feed embed look.
//

import SwiftUI

enum CatbirdNoticeTone: CaseIterable, Sendable {
  case info, warning, error, success

  var color: Color {
    switch self {
    case .info: return .accentColor
    case .warning: return .orange
    case .error: return .red
    case .success: return .green
    }
  }

  var systemImage: String {
    switch self {
    case .info: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .error: return "xmark.octagon.fill"
    case .success: return "checkmark.circle.fill"
    }
  }
}

enum CatbirdCardStyle: Sendable, Equatable {
  /// Secondary-background fill, hairline stroke, r12. Quote/link/site embeds.
  case embed
  /// Same fill, no stroke, r16. Grouped panels.
  case panel
  /// Tinted fill + matching hairline, r12.
  case notice(CatbirdNoticeTone)

  var defaultRadius: Radius {
    switch self {
    case .embed, .notice: return .md
    case .panel: return .lg
    }
  }
}

extension View {
  /// Wrap in Catbird card chrome. `radius` defaults to the style's radius.
  func catbirdCard(_ style: CatbirdCardStyle = .embed, radius: Radius? = nil) -> some View {
    modifier(CatbirdCardModifier(style: style, radius: radius ?? style.defaultRadius))
  }
}

private struct CatbirdCardModifier: ViewModifier {
  let style: CatbirdCardStyle
  let radius: Radius

  @ViewBuilder func body(content: Content) -> some View {
    let shape = radius.shape
    switch style {
    case .embed:
      content
        .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground))
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.gray.opacity(0.3), lineWidth: 1) }
    case .panel:
      content
        .background(Color(platformColor: PlatformColor.platformSecondarySystemBackground))
        .clipShape(shape)
    case .notice(let tone):
      content
        .background(tone.color.opacity(0.12))
        .clipShape(shape)
        .overlay { shape.strokeBorder(tone.color.opacity(0.3), lineWidth: 1) }
    }
  }
}

#Preview("Cards") {
  VStack(spacing: Space.md) {
    Text(verbatim: "Embed").padding().frame(maxWidth: .infinity, alignment: .leading).catbirdCard(.embed)
    Text(verbatim: "Panel").padding().frame(maxWidth: .infinity, alignment: .leading).catbirdCard(.panel)
    ForEach(CatbirdNoticeTone.allCases, id: \.self) { tone in
      Text(verbatim: "Notice").padding().frame(maxWidth: .infinity, alignment: .leading)
        .catbirdCard(.notice(tone))
    }
  }
  .padding(Space.screenMargin)
}
