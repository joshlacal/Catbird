//
//  CatbirdTokens.swift
//  Catbird
//
//  Token layer for the Catbird UI kit (docs/execution-plans/2026-11-25-catbird-ui-cohesion.md).
//  Spacing and motion intent come from CatbirdBrand; the radius scale is local
//  (decision 1 in the plan: the tuned feed is the reference, not Brand.radius).
//  New code uses these. `DesignTokens` (3pt grid) is legacy.
//

import CatbirdBrand
import SwiftUI

// MARK: - Space

/// 4pt spacing scale sourced from `Brand.space`.
///
/// | name | pt | Brand key |
/// |------|----|-----------|
/// | hairline | 2 | fine |
/// | xs | 4 | s1 |
/// | sm | 8 | s2 |
/// | md | 12 | s3 |
/// | lg | 16 | s4 |
/// | xl | 20 | s5 |
/// | xxl | 24 | s6 |
/// | x3l | 32 | s8 |
/// | x4l | 40 | s10 |
/// | x5l | 48 | s12 |
/// | x6l | 64 | s16 |
enum Space {
  static let hairline = CGFloat(Brand.space.fine)
  static let xs = CGFloat(Brand.space.s1)
  static let sm = CGFloat(Brand.space.s2)
  static let md = CGFloat(Brand.space.s3)
  static let lg = CGFloat(Brand.space.s4)
  static let xl = CGFloat(Brand.space.s5)
  static let xxl = CGFloat(Brand.space.s6)
  static let x3l = CGFloat(Brand.space.s8)
  static let x4l = CGFloat(Brand.space.s10)
  static let x5l = CGFloat(Brand.space.s12)
  static let x6l = CGFloat(Brand.space.s16)

  /// Horizontal screen margin for full-width content.
  static let screenMargin: CGFloat = 16
}

// MARK: - Radius

/// In-app corner radius scale: 4 / 8 / 12 / 16 / 24, always `.continuous`.
enum Radius: CGFloat, CaseIterable, Sendable {
  case xs = 4
  case sm = 8
  case md = 12
  case lg = 16
  case xl = 24

  var value: CGFloat { rawValue }

  /// Continuous rounded rectangle at this radius.
  var shape: RoundedRectangle { RoundedRectangle(cornerRadius: rawValue, style: .continuous) }

  /// Pill shape (continuous).
  static var capsule: Capsule { Capsule(style: .continuous) }
}

extension View {
  /// Clip to a continuous rounded rectangle from the radius scale.
  func catbirdClip(_ radius: Radius) -> some View {
    clipShape(radius.shape)
  }

  /// Clip to a pill.
  func catbirdClipCapsule() -> some View {
    clipShape(Radius.capsule)
  }
}

// MARK: - Control sizes

/// Visual control heights. Hit targets are always at least 44pt regardless.
enum ControlHeight {
  static let sm: CGFloat = 32
  static let md: CGFloat = 40
  static let lg: CGFloat = 48
  /// Minimum interactive hit target.
  static let minHitTarget: CGFloat = 44
}

/// Avatar diameters.
enum AvatarSize {
  static let xs: CGFloat = 24
  static let sm: CGFloat = 32
  static let md: CGFloat = 40
  static let lg: CGFloat = 48
  static let xl: CGFloat = 64
  static let xxl: CGFloat = 96
}

// MARK: - Motion

/// Motion intents.
///
/// Source: `Brand.motion.<intent>.iosSwiftUI`. Those bindings are strings
/// (e.g. `.spring(response: 0.35, dampingFraction: 0.85)`), so they are
/// hand-mapped here and must be kept in sync with `docs/brand/05-motion.md`.
/// `gesture` is "runtime configured" in the spec; mapped to an interactive spring.
enum Motion {
  /// `.smooth(duration: 0.15)`
  static let instant: Animation = .smooth(duration: 0.15)
  /// `.spring(response: 0.35, dampingFraction: 0.85)`
  static let enter: Animation = .spring(response: 0.35, dampingFraction: 0.85)
  /// `.easeOut(duration: 0.22)`
  static let exit: Animation = .easeOut(duration: 0.22)
  /// `.spring(response: 0.4, dampingFraction: 0.65)`
  static let emphasis: Animation = .spring(response: 0.4, dampingFraction: 0.65)
  /// Interactive spring for drag-tracking.
  static let gesture: Animation = .interactiveSpring()

  /// Returns `nil` (no animation) when Reduce Motion is on.
  static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : animation
  }

  /// `withAnimation` that is skipped under Reduce Motion.
  static func withAnimation<Result>(
    _ animation: Animation, reduceMotion: Bool, _ body: () throws -> Result
  ) rethrows -> Result {
    try SwiftUI.withAnimation(resolved(animation, reduceMotion: reduceMotion), body)
  }
}

private struct CatbirdAnimationModifier<V: Equatable>: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let animation: Animation
  let value: V

  func body(content: Content) -> some View {
    content.animation(Motion.resolved(animation, reduceMotion: reduceMotion), value: value)
  }
}

extension View {
  /// `.animation(_:value:)` that is skipped under Reduce Motion.
  func catbirdAnimation<V: Equatable>(_ animation: Animation = Motion.enter, value: V) -> some View {
    modifier(CatbirdAnimationModifier(animation: animation, value: value))
  }
}

// MARK: - Elevation

/// Surface elevation. Subtle shadows only; the feed is flat.
enum Elevation: CaseIterable, Sendable {
  case flat
  case raised
  case floating

  fileprivate var shadow: (opacity: Double, radius: CGFloat, y: CGFloat) {
    switch self {
    case .flat: return (0, 0, 0)
    case .raised: return (0.06, 4, 1)
    case .floating: return (0.14, 16, 6)
    }
  }
}

extension View {
  /// Apply a token elevation shadow.
  func catbirdElevation(_ elevation: Elevation) -> some View {
    let s = elevation.shadow
    return shadow(color: .black.opacity(s.opacity), radius: s.radius, x: 0, y: s.y)
  }
}

// MARK: - Brand gradient

/// 135° gradient from the active accent toward its palette `gradientPartner`
/// (docs/brand/02-color.md), the end stop mixed 50% back to the accent for label contrast.
/// Use sparingly: hero buttons, brand moments (`CatbirdButtonKind.brand`).
enum BrandGradient {
  private static func palette(for option: AccentColorOption) -> Palette {
    switch option {
    case .catbird: return Brand.color.catbird
    case .twilight: return Brand.color.twilight
    case .lavender: return Brand.color.lavender
    case .sunrise: return Brand.color.sunrise
    case .aurora: return Brand.color.aurora
    case .dusk: return Brand.color.dusk
    case .midnight: return Brand.color.midnight
    }
  }

  private typealias Palette = catbird_Color.Palette

  private static func color(hex: String) -> Color? {
    let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    return Color(
      .displayP3,
      red: Double((v >> 16) & 0xff) / 255,
      green: Double((v >> 8) & 0xff) / 255,
      blue: Double(v & 0xff) / 255)
  }

  static let startPoint = UnitPoint.topLeading
  static let endPoint = UnitPoint.bottomTrailing

  /// Start and end colours for an accent palette.
  static func colors(for option: AccentColorOption, scheme: ColorScheme) -> (start: Color, end: Color) {
    let p = palette(for: option)
    // The default palette follows the asset-catalog accent (same colour `.tint` resolves to),
    // so a brand gradient starts from exactly the colour solid primary buttons use.
    let start: Color =
      option == .catbird
      ? Color.accentColor
      : (color(hex: scheme == .dark ? p.accentDark : p.accentLight) ?? .accentColor)
    let partner = color(hex: p.gradientPartner) ?? start
    // Pull the end stop halfway back toward the accent so white labels keep >= 3:1 contrast.
    let end = start.mix(with: partner, by: 0.5)
    return (start, end)
  }

  /// Gradient for the active theme accent.
  static func current(themeManager: ThemeManager?, scheme: ColorScheme = .light) -> LinearGradient {
    guard let themeManager else { return fallback }
    let c = colors(for: themeManager.currentAccentColor, scheme: scheme)
    return LinearGradient(colors: [c.start, c.end], startPoint: startPoint, endPoint: endPoint)
  }

  /// Environment-free fallback: accent colour to a lighter tint of itself.
  static var fallback: LinearGradient {
    LinearGradient(
      colors: [Color.accentColor, Color.accentColor.mix(with: .white, by: 0.15)],
      startPoint: startPoint, endPoint: endPoint)
  }
}

/// Fills its frame with the brand gradient for the active theme (reads the
/// theme from the environment; falls back to accent when absent).
struct BrandGradientFill: View {
  @Environment(\.themeManager) private var themeManager
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    Rectangle().fill(BrandGradient.current(themeManager: themeManager, scheme: scheme))
  }
}

#Preview("Tokens") {
  VStack(alignment: .leading, spacing: Space.md) {
    ForEach(Radius.allCases, id: \.self) { r in
      r.shape.fill(Color.accentColor.opacity(0.2)).frame(height: 32)
        .overlay(Text("Radius \(Int(r.value))").font(.caption))
    }
    BrandGradientFill().frame(height: 48).catbirdClip(.lg)
  }
  .padding(Space.screenMargin)
}
