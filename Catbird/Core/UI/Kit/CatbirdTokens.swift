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

/// Semantic motion intents aligned with `docs/brand/05-motion.md`.
enum MotionIntent: CaseIterable, Sendable {
  case instant
  case enter
  case exit
  case emphasis
  case gesture

  /// Native animation curve respecting Reduce Motion (`docs/brand/05-motion.md §Reduce Motion`:
  /// springs flatten to gentle non-overshooting linear/easeOut crossfades rather than bouncing).
  func animation(reduceMotion: Bool) -> Animation {
    if reduceMotion {
      switch self {
      case .instant, .gesture:
        return .linear(duration: 0.15)
      case .enter:
        return .easeOut(duration: 0.22)
      case .exit:
        return .easeOut(duration: 0.18)
      case .emphasis:
        return .easeOut(duration: 0.20)
      }
    }
    switch self {
    case .instant: return Motion.instant
    case .enter: return Motion.enter
    case .exit: return Motion.exit
    case .emphasis: return Motion.emphasis
    case .gesture: return Motion.gesture
    }
  }
}

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
  /// Gentle non-overshooting fallback curve used when Reduce Motion flattens springs.
  static let reducedCrossfade: Animation = .easeOut(duration: 0.15)

  /// Resolve an animation under Reduce Motion.
  /// Per `docs/brand/05-motion.md`, springs flatten to a gentle crossfade (`reducedCrossfade`)
  /// by default; pass `reducedFallback: nil` when motion should be omitted completely.
  static func resolved(
    _ animation: Animation,
    reduceMotion: Bool,
    reducedFallback: Animation? = Motion.reducedCrossfade
  ) -> Animation? {
    reduceMotion ? reducedFallback : animation
  }

  /// Resolve a semantic motion intent under Reduce Motion.
  static func resolved(_ intent: MotionIntent, reduceMotion: Bool) -> Animation {
    intent.animation(reduceMotion: reduceMotion)
  }

  /// `withAnimation` that honors Reduce Motion semantics.
  static func withAnimation<Result>(
    _ animation: Animation,
    reduceMotion: Bool,
    reducedFallback: Animation? = Motion.reducedCrossfade,
    _ body: () throws -> Result
  ) rethrows -> Result {
    try SwiftUI.withAnimation(
      resolved(animation, reduceMotion: reduceMotion, reducedFallback: reducedFallback),
      body
    )
  }

  /// `withAnimation` for a semantic motion intent.
  static func withAnimation<Result>(
    _ intent: MotionIntent,
    reduceMotion: Bool,
    _ body: () throws -> Result
  ) rethrows -> Result {
    try SwiftUI.withAnimation(intent.animation(reduceMotion: reduceMotion), body)
  }
}

private struct CatbirdAnimationModifier<V: Equatable>: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let animation: Animation
  let reducedFallback: Animation?
  let value: V

  func body(content: Content) -> some View {
    content.animation(
      Motion.resolved(animation, reduceMotion: reduceMotion, reducedFallback: reducedFallback),
      value: value
    )
  }
}

private struct CatbirdMotionIntentModifier<V: Equatable>: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let intent: MotionIntent
  let value: V

  func body(content: Content) -> some View {
    content.animation(intent.animation(reduceMotion: reduceMotion), value: value)
  }
}

extension View {
  /// `.animation(_:value:)` that respects Reduce Motion (flattening springs to a gentle crossfade by default).
  func catbirdAnimation<V: Equatable>(
    _ animation: Animation = Motion.enter,
    reducedFallback: Animation? = Motion.reducedCrossfade,
    value: V
  ) -> some View {
    modifier(
      CatbirdAnimationModifier(animation: animation, reducedFallback: reducedFallback, value: value)
    )
  }

  /// `.animation(_:value:)` for a semantic `MotionIntent` that flattens springs under Reduce Motion.
  func catbirdAnimation<V: Equatable>(_ intent: MotionIntent, value: V) -> some View {
    modifier(CatbirdMotionIntentModifier(intent: intent, value: value))
  }
}

// MARK: - Elevation

/// Surface elevation. Subtle shadows in Light/Dim; suppressed on OLED True Black per `docs/brand/06-materials.md`.
enum Elevation: CaseIterable, Sendable {
  case flat
  case raised
  case floating

  fileprivate var metrics: (opacityFactor: Double, radius: CGFloat, y: CGFloat) {
    switch self {
    case .flat: return (0, 0, 0)
    case .raised: return (0.45, 4, 1)
    case .floating: return (0.90, 16, 6)
    }
  }
}

private struct CatbirdElevationModifier: ViewModifier {
  @Environment(\.catbirdTheme) private var theme
  let elevation: Elevation

  func body(content: Content) -> some View {
    let m = elevation.metrics
    let color: Color =
      (elevation == .flat || theme.isTrueBlack)
      ? .clear
      : theme.shadowColor().opacity(m.opacityFactor)
    content.shadow(color: color, radius: m.radius, x: 0, y: m.y)
  }
}

extension View {
  /// Apply a theme-aware token elevation shadow (suppressed in True Black OLED mode).
  func catbirdElevation(_ elevation: Elevation) -> some View {
    modifier(CatbirdElevationModifier(elevation: elevation))
  }
}

// MARK: - Brand gradient

/// 135° gradient from the active accent toward its palette `gradientPartner`
/// (`docs/brand/02-color.md`), parsed in sRGB to match `docs/brand/contrast-audit.md`,
/// with the end stop mixed 50% back to the accent for label contrast.
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
      .sRGB,
      red: Double((v >> 16) & 0xff) / 255,
      green: Double((v >> 8) & 0xff) / 255,
      blue: Double(v & 0xff) / 255)
  }

  static let startPoint = UnitPoint.topLeading
  static let endPoint = UnitPoint.bottomTrailing

  /// True when the palette's gradient start and partner are identical in `scheme`
  /// (common in Dark mode), so callers can render a solid fill without 1-LSB gradient dithering.
  static func isSolid(for option: AccentColorOption, scheme: ColorScheme) -> Bool {
    let p = palette(for: option)
    let startHex = (scheme == .dark ? p.accentDark : p.accentLight).uppercased()
    let partnerHex = p.gradientPartner.uppercased()
    return startHex == partnerHex
  }

  /// Start and end colours for an accent palette in sRGB.
  static func colors(for option: AccentColorOption, scheme: ColorScheme) -> (start: Color, end: Color) {
    let p = palette(for: option)
    let startHex = scheme == .dark ? p.accentDark : p.accentLight
    let startSRGB = CatbirdSRGBColor(hex: startHex) ?? .catbirdFallbackAccent
    let start = startSRGB.swiftUIColor
    let partner = color(hex: p.gradientPartner) ?? start
    // Light-ink palettes (`#FFFFFF` onAccent, e.g. twilight/midnight light) use a tighter 25%
    // blend toward the lighter partner so both ends stay >= 4.65:1; dark-ink palettes (`#0B0D12`)
    // gain contrast toward the lighter partner at 50% and keep a clean, distinct gradient stop.
    let blend = CatbirdSRGBColor.onAccent(for: startSRGB) == .pureWhite ? 0.25 : 0.5
    let end = start.mix(with: partner, by: blend)
    return (start, end)
  }

  /// Gradient for an explicit resolved `CatbirdThemeColors`.
  static func current(theme: CatbirdThemeColors) -> LinearGradient {
    let c = colors(for: theme.accentOption, scheme: theme.colorScheme)
    return LinearGradient(colors: [c.start, c.end], startPoint: startPoint, endPoint: endPoint)
  }

  /// Gradient for the active theme accent.
  static func current(themeManager: ThemeManager?, scheme: ColorScheme = .light) -> LinearGradient {
    guard let themeManager else { return fallback }
    let effective = themeManager.effectiveColorScheme(for: scheme)
    let c = colors(for: themeManager.currentAccentColor, scheme: effective)
    return LinearGradient(colors: [c.start, c.end], startPoint: startPoint, endPoint: endPoint)
  }

  /// Environment-free fallback: accent colour to a lighter tint of itself.
  static var fallback: LinearGradient {
    let c = colors(for: .catbird, scheme: .light)
    return LinearGradient(colors: [c.start, c.end], startPoint: startPoint, endPoint: endPoint)
  }
}

/// Fills its frame with the brand gradient for the active theme.
struct BrandGradientFill: View {
  @Environment(\.catbirdTheme) private var theme

  var body: some View {
    Rectangle().fill(BrandGradient.current(theme: theme))
  }
}

#Preview("Tokens") {
  VStack(alignment: .leading, spacing: Space.md) {
    ForEach(Radius.allCases, id: \.self) { r in
      r.shape.fill(Color.accentColor.opacity(0.2)).frame(height: 32)
        .overlay(Text("Radius \(Int(r.value))").appFont(AppTextRole.caption))
    }
    BrandGradientFill().frame(height: 48).catbirdClip(.lg)
  }
  .padding(Space.screenMargin)
}
