//
//  CatbirdButtonStyle.swift
//  Catbird
//
//  One capsule button style at three heights, plus a round icon button.
//
//  Colour: accent parts use the `.tint` shape style, so `.tint(_:)` re-tints a button
//  (CatbirdNotice relies on this). `.primary` is a solid tint fill at every size;
//  `.brand` is the opt-in hero gradient. `.glass` and `.glassProminent` are Liquid Glass
//  for buttons that float over imagery (the sign-in sky, media, maps); on plain
//  backgrounds use the solid kinds. Hit targets are always >= 44x44.
//  CatbirdIconButton scales its glyph and circle with Dynamic Type (clamped to 1.5x).
//

import SwiftUI

enum CatbirdButtonKind: CaseIterable, Sendable {
  /// Solid tint fill, white label. Same look at every size.
  case primary
  /// Opt-in hero button: brand gradient (accent toward palette partner), white label.
  case brand
  case tonal
  /// Hairline stroke, primary label.
  case outline
  /// Hairline stroke, secondary label. Disabled-looking state that is not dimmed (e.g. Blocked).
  case muted
  case quiet
  case destructive
  /// Liquid Glass capsule, primary label. For secondary actions over imagery.
  /// Falls back to a material before iOS 26 and to an opaque fill under Reduce Transparency.
  case glass
  /// Liquid Glass tinted with the accent, white label. For the main action over imagery.
  /// Falls back to a solid tint fill before iOS 26 and under Reduce Transparency.
  case glassProminent
}

enum CatbirdButtonSize: CaseIterable, Sendable {
  case sm, md, lg

  /// Visual capsule height.
  var height: CGFloat {
    switch self {
    case .sm: return ControlHeight.sm
    case .md: return ControlHeight.md
    case .lg: return ControlHeight.lg
    }
  }

  var horizontalPadding: CGFloat {
    switch self {
    case .sm: return Space.md
    case .md: return Space.lg
    case .lg: return Space.xl
    }
  }

  /// footnote.semibold / subheadline.semibold / headline
  var textRole: AppTextRole {
    switch self {
    case .sm: return .footnote
    case .md: return .subheadline
    case .lg: return .headline
    }
  }
}

/// `.buttonStyle(.catbird(.primary, size: .lg, fullWidth: true))`
struct CatbirdButtonStyle: ButtonStyle {
  var kind: CatbirdButtonKind = .primary
  var size: CatbirdButtonSize = .md
  var fullWidth = false
  var isLoading = false

  func makeBody(configuration: Configuration) -> some View {
    CatbirdButtonBody(
      configuration: configuration, kind: kind, size: size, fullWidth: fullWidth,
      isLoading: isLoading)
  }
}

extension ButtonStyle where Self == CatbirdButtonStyle {
  static func catbird(
    _ kind: CatbirdButtonKind = .primary,
    size: CatbirdButtonSize = .md,
    fullWidth: Bool = false,
    isLoading: Bool = false
  ) -> CatbirdButtonStyle {
    CatbirdButtonStyle(kind: kind, size: size, fullWidth: fullWidth, isLoading: isLoading)
  }
}

private struct CatbirdButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let kind: CatbirdButtonKind
  let size: CatbirdButtonSize
  let fullWidth: Bool
  let isLoading: Bool

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.themeManager) private var themeManager
  @Environment(\.colorScheme) private var scheme
  @Environment(\.colorSchemeContrast) private var contrast

  private var increased: Bool { contrast == .increased }

  private var foreground: AnyShapeStyle {
    switch kind {
    case .primary, .brand, .glassProminent: return AnyShapeStyle(Color.white)
    case .tonal, .quiet: return AnyShapeStyle(TintShapeStyle())
    case .outline, .glass: return AnyShapeStyle(Color.primary)
    case .muted: return AnyShapeStyle(Color.secondary)
    case .destructive: return AnyShapeStyle(Color.red)
    }
  }

  /// Never the tint shape style itself: a tint that resolves to the tint recurses forever.
  private var spinnerTint: AnyShapeStyle? {
    switch kind {
    case .tonal, .quiet: return nil
    default: return foreground
    }
  }

  var body: some View {
    let pressed = configuration.isPressed
    configuration.label
      .appFont(size.textRole)
      .fontWeight(.semibold)
      .lineLimit(1)
      .minimumScaleFactor(0.85)
      .opacity(isLoading ? 0 : 1)
      .overlay {
        if isLoading {
          ProgressView().tint(spinnerTint)
        }
      }
      .foregroundStyle(foreground)
      .padding(.horizontal, size.horizontalPadding)
      .frame(minHeight: size.height)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .background { background }
      .modifier(CatbirdGlassChrome(kind: kind))
      .overlay {
        if kind == .outline || kind == .muted {
          Capsule(style: .continuous)
            .strokeBorder(Color.secondary.opacity(increased ? 0.6 : 0.35), lineWidth: 1)
        }
      }
      // Visual height stays 32/40/48; the layout box grows to the 44pt hit target.
      .frame(minWidth: ControlHeight.minHitTarget, minHeight: ControlHeight.minHitTarget)
      .contentShape(Rectangle())
      .scaleEffect(pressed ? 0.97 : 1)
      .opacity(pressed ? 0.85 : 1)
      // A loading button keeps full strength; only a disabled one dims.
      .opacity(isEnabled || isLoading ? 1 : 0.4)
      .allowsHitTesting(!isLoading)
      .accessibilityAddTraits(isLoading ? .updatesFrequently : [])
      .catbirdAnimation(Motion.instant, value: pressed)
  }

  @ViewBuilder private var background: some View {
    let shape = Capsule(style: .continuous)
    let tonal = increased ? 0.22 : 0.14
    switch kind {
    case .primary: shape.fill(TintShapeStyle())
    case .brand: shape.fill(BrandGradient.current(themeManager: themeManager, scheme: scheme))
    case .tonal: shape.fill(TintShapeStyle().opacity(tonal))
    case .destructive: shape.fill(Color.red.opacity(tonal))
    case .outline, .muted, .quiet, .glass, .glassProminent: Color.clear
    }
  }
}

/// Draws the Liquid Glass capsule for the two glass kinds and nothing for the others.
private struct CatbirdGlassChrome: ViewModifier {
  let kind: CatbirdButtonKind
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  @ViewBuilder func body(content: Content) -> some View {
    switch kind {
    case .glass, .glassProminent:
      let prominent = kind == .glassProminent
      let shape = Capsule(style: .continuous)
      if reduceTransparency {
        content.background {
          shape.fill(prominent ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.systemBackground))
        }
      } else if #available(iOS 26.0, macOS 26.0, *) {
        content.glassEffect(
          prominent ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
          in: shape)
      } else {
        content.background {
          shape.fill(prominent ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(.regularMaterial))
        }
      }
    default:
      content
    }
  }
}

// MARK: - Icon button

enum CatbirdIconButtonStyle: Sendable {
  case tonal, quiet
  /// Liquid Glass on iOS 26, material fallback before.
  case glass
}

/// Round SF Symbol button. Visual 32/40/48 (scaled with Dynamic Type, max 1.5x), 44pt minimum hit target.
struct CatbirdIconButton: View {
  let systemImage: String
  var label: Text
  var size: CatbirdButtonSize = .md
  var style: CatbirdIconButtonStyle = .tonal
  var action: () -> Void

  @Environment(\.isEnabled) private var isEnabled
  @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

  init(
    systemImage: String, label: LocalizedStringKey, size: CatbirdButtonSize = .md,
    style: CatbirdIconButtonStyle = .tonal, action: @escaping () -> Void
  ) {
    self.init(
      systemImage: systemImage, label: Text(label), size: size, style: style, action: action)
  }

  init(
    systemImage: String, label: Text, size: CatbirdButtonSize = .md,
    style: CatbirdIconButtonStyle = .tonal, action: @escaping () -> Void
  ) {
    self.systemImage = systemImage
    self.label = label
    self.size = size
    self.style = style
    self.action = action
  }

  private var glyphSize: CGFloat {
    switch size {
    case .sm: return 14
    case .md: return 17
    case .lg: return 20
    }
  }

  private var side: CGFloat { size.height * min(scale, 1.5) }

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .appFont(size: glyphSize, weight: .semibold, relativeTo: .body)
        .foregroundStyle(TintShapeStyle())
        .frame(width: side, height: side)
        .modifier(IconChrome(style: style))
        .frame(minWidth: ControlHeight.minHitTarget, minHeight: ControlHeight.minHitTarget)
        .contentShape(Rectangle())
    }
    .buttonStyle(CatbirdIconPressStyle())
    .opacity(isEnabled ? 1 : 0.4)
    .accessibilityLabel(label)
  }
}

private struct IconChrome: ViewModifier {
  let style: CatbirdIconButtonStyle
  @Environment(\.colorSchemeContrast) private var contrast

  @ViewBuilder func body(content: Content) -> some View {
    switch style {
    case .tonal:
      content.background(Circle().fill(TintShapeStyle().opacity(contrast == .increased ? 0.22 : 0.14)))
    case .quiet:
      content
    case .glass:
      // adaptiveGlassEffect falls back to a material before iOS 26.
      content.adaptiveGlassEffect(in: Circle(), interactive: true)
    }
  }
}

private struct CatbirdIconPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .catbirdAnimation(Motion.instant, value: configuration.isPressed)
  }
}

#Preview("Buttons") {
  VStack(alignment: .leading, spacing: Space.md) {
    ForEach(CatbirdButtonKind.allCases, id: \.self) { kind in
      HStack {
        ForEach(CatbirdButtonSize.allCases, id: \.self) { size in
          Button { } label: { Text(verbatim: "Label") }.buttonStyle(.catbird(kind, size: size))
        }
      }
    }
    Button { } label: { Text(verbatim: "Continue") }
      .buttonStyle(.catbird(.brand, size: .lg, fullWidth: true))
    Button { } label: { Text(verbatim: "Loading") }
      .buttonStyle(.catbird(.primary, size: .md, isLoading: true))
    HStack {
      CatbirdIconButton(systemImage: "plus", label: Text(verbatim: "Add"), size: .sm) {}
      CatbirdIconButton(systemImage: "plus", label: Text(verbatim: "Add"), size: .md, style: .glass) {}
      CatbirdIconButton(systemImage: "plus", label: Text(verbatim: "Add"), size: .lg, style: .quiet) {}
    }
  }
  .padding(Space.screenMargin)
}
