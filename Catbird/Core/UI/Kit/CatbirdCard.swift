//
//  CatbirdCard.swift
//  Catbird
//
//  Unified semantic tone (`CatbirdTone`) and theme-aware card chrome.
//  `.embed` / `.panel` / `.notice` resolve surface and border colors from `@Environment(\.catbirdTheme)`
//  so Light, Dim, True Black, and Increased Contrast stay consistent across the app.
//

import SwiftUI

/// Unified semantic tone shared across `CatbirdBadge`, `CatbirdNotice`, and `.catbirdCard(.notice(_:))`.
enum CatbirdTone: CaseIterable, Sendable, Hashable {
  case neutral
  case info
  case accent
  case success
  case warning
  case danger

  /// Compatibility alias for `CatbirdNoticeTone.error` call sites.
  static let error: CatbirdTone = .danger

  var semanticTone: CatbirdSemanticTone {
    switch self {
    case .neutral: return .neutral
    case .info: return .info
    case .accent: return .accent
    case .success: return .success
    case .warning: return .warning
    case .danger: return .danger
    }
  }

  /// Resolved color from the active `CatbirdThemeColors`.
  func color(in theme: CatbirdThemeColors) -> Color {
    theme.semantic(semanticTone)
  }

  /// Environment-free fallback color (prefer `color(in: catbirdTheme)` inside SwiftUI views).
  var color: Color {
    color(in: CatbirdThemeColors.resolve(colorScheme: .light))
  }

  var systemImage: String {
    switch self {
    case .neutral: return "circle.fill"
    case .info, .accent: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .danger: return "xmark.octagon.fill"
    case .success: return "checkmark.circle.fill"
    }
  }
}

/// Source-compatible alias for notice call sites.
typealias CatbirdNoticeTone = CatbirdTone

/// Source-compatible alias for badge call sites.
typealias CatbirdBadgeTone = CatbirdTone

enum CatbirdCardStyle: Sendable, Equatable {
  /// Card surface fill, hairline border, r12. Quote/link/site embeds.
  case embed
  /// Elevated surface fill, r16 (adds subtle border on OLED True Black / high contrast).
  case panel
  /// Tinted semantic fill + matching hairline, r12.
  case notice(CatbirdTone)

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
  @Environment(\.catbirdTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  let style: CatbirdCardStyle
  let radius: Radius

  private var increased: Bool { theme.isHighContrast || contrast == .increased }

  @ViewBuilder func body(content: Content) -> some View {
    let shape = radius.shape
    switch style {
    case .embed:
      content
        .background(theme.surface(.card))
        .clipShape(shape)
        .overlay {
          shape.strokeBorder(
            theme.border(increased ? .prominent : .subtle),
            lineWidth: increased ? 1.5 : 1
          )
        }
    case .panel:
      content
        .background(theme.surface(.elevated))
        .clipShape(shape)
        .overlay {
          if theme.isTrueBlack || increased {
            shape.strokeBorder(
              theme.border(increased ? .prominent : .subtle),
              lineWidth: 1
            )
          }
        }
    case .notice(let tone):
      let tint = tone.color(in: theme)
      content
        .background(tint.opacity(increased ? 0.2 : 0.12))
        .clipShape(shape)
        .overlay {
          shape.strokeBorder(
            tint.opacity(increased ? 0.55 : 0.3),
            lineWidth: increased ? 1.5 : 1
          )
        }
    }
  }
}

#Preview("Cards") {
  VStack(spacing: Space.md) {
    Text(verbatim: "Embed").padding().frame(maxWidth: .infinity, alignment: .leading).catbirdCard(.embed)
    Text(verbatim: "Panel").padding().frame(maxWidth: .infinity, alignment: .leading).catbirdCard(.panel)
    ForEach([CatbirdTone.info, .warning, .error, .success], id: \.self) { tone in
      Text(verbatim: "Notice").padding().frame(maxWidth: .infinity, alignment: .leading)
        .catbirdCard(.notice(tone))
    }
  }
  .padding(Space.screenMargin)
}
