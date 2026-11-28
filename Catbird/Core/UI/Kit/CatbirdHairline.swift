//
//  CatbirdHairline.swift
//  Catbird
//
//  Theme-aware 1px hairline divider honoring container-specific separator extent rules
//  (Catbird/docs/settings-design-rules.md: full-width feed/notification boundaries vs
//  content-inset list boundaries).
//

import SwiftUI

enum CatbirdHairlineExtent: Equatable, Sendable {
  /// Edge-to-edge separator (feed rows, notifications, search results).
  case fullWidth
  /// Inset symmetrically on both leading and trailing edges.
  case contentInset(CGFloat = Space.screenMargin)
  /// Leading inset only (aligned to row text past an avatar or leading icon).
  case leadingInset(CGFloat)
}

struct CatbirdHairline: View {
  var axis: Axis = .horizontal
  var extent: CatbirdHairlineExtent = .fullWidth
  var prominent: Bool = false

  @Environment(\.catbirdTheme) private var theme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.colorSchemeContrast) private var contrast

  private var increased: Bool { theme.isHighContrast || contrast == .increased }

  private var thickness: CGFloat {
    if prominent || increased {
      return 1
    }
    return 1 / max(displayScale, 1)
  }

  private var color: Color {
    theme.border((prominent || increased) ? .prominent : .subtle)
  }

  var body: some View {
    line
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private var line: some View {
    switch axis {
    case .horizontal:
      Rectangle()
        .fill(color)
        .frame(height: thickness)
        .padding(horizontalInsets)
    case .vertical:
      Rectangle()
        .fill(color)
        .frame(width: thickness)
    }
  }

  private var horizontalInsets: EdgeInsets {
    switch extent {
    case .fullWidth:
      return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
    case .contentInset(let inset):
      return EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset)
    case .leadingInset(let inset):
      return EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: 0)
    }
  }
}

#Preview("Hairlines") {
  VStack(spacing: Space.lg) {
    CatbirdHairline(extent: .fullWidth)
    CatbirdHairline(extent: .contentInset())
    CatbirdHairline(extent: .leadingInset(AvatarSize.lg + Space.md))
    CatbirdHairline(prominent: true)
  }
  .padding(.vertical, Space.lg)
}
