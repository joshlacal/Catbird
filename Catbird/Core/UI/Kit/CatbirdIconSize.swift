//
//  CatbirdIconSize.swift
//  Catbird
//
//  Icon sizing scale and SF Symbol role styling aligned with docs/brand/07-iconography.md.
//

import SwiftUI

/// Standard icon sizing scale on the 4pt grid (`docs/brand/07-iconography.md`).
enum IconSize: Sendable {
  /// Inline with body/subheadline text (matches cap height).
  static let inline: CGFloat = 14
  /// Small icons inside chips, compact buttons, and badges.
  static let sm: CGFloat = 16
  /// List row leading icons (20pt per spec).
  static let md: CGFloat = 20
  /// Navigation, toolbar, tab bar, and FAB icons (24pt per spec).
  static let lg: CGFloat = 24
  /// Section and feature card glyphs.
  static let xl: CGFloat = 32
  /// Empty and error state hero icons.
  static let hero: CGFloat = 48
}

/// Semantic SF Symbol sizing, weight, and rendering-mode roles.
enum CatbirdSymbolRole: CaseIterable, Sendable {
  case inline
  case compact
  case row
  case toolbar
  case prominent
  case hero

  var pointSize: CGFloat {
    switch self {
    case .inline: return IconSize.inline
    case .compact: return IconSize.sm
    case .row: return IconSize.md
    case .toolbar: return IconSize.lg
    case .prominent: return IconSize.xl
    case .hero: return IconSize.hero
    }
  }

  var defaultWeight: Font.Weight {
    switch self {
    case .inline, .row: return .regular
    case .compact, .toolbar: return .semibold
    case .prominent, .hero: return .medium
    }
  }

  var relativeTextStyle: Font.TextStyle {
    switch self {
    case .inline: return .subheadline
    case .compact: return .footnote
    case .row, .toolbar: return .body
    case .prominent: return .title2
    case .hero: return .largeTitle
    }
  }

  var defaultRenderingMode: SymbolRenderingMode {
    switch self {
    case .inline, .compact, .row, .toolbar: return .monochrome
    case .prominent, .hero: return .hierarchical
    }
  }
}

private struct CatbirdSymbolModifier: ViewModifier {
  let role: CatbirdSymbolRole
  let weight: Font.Weight?
  let renderingMode: SymbolRenderingMode?

  func body(content: Content) -> some View {
    content
      .appFont(
        size: role.pointSize,
        weight: weight ?? role.defaultWeight,
        relativeTo: role.relativeTextStyle
      )
      .symbolRenderingMode(renderingMode ?? role.defaultRenderingMode)
  }
}

extension View {
  /// Style an SF Symbol with Catbird's icon scale, weight, and rendering mode while respecting FontManager.
  func catbirdSymbol(
    _ role: CatbirdSymbolRole,
    weight: Font.Weight? = nil,
    renderingMode: SymbolRenderingMode? = nil
  ) -> some View {
    modifier(CatbirdSymbolModifier(role: role, weight: weight, renderingMode: renderingMode))
  }
}

#Preview("Icon sizes") {
  HStack(spacing: Space.lg) {
    ForEach(CatbirdSymbolRole.allCases, id: \.self) { role in
      VStack(spacing: Space.xs) {
        Image(systemName: "sparkles")
          .catbirdSymbol(role)
        Text(verbatim: "\(Int(role.pointSize))")
          .appFont(AppTextRole.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }
  .padding(Space.screenMargin)
}
