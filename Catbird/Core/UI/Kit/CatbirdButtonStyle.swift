//
//  CatbirdButtonStyle.swift
//  Catbird
//
//  One capsule button style at three heights, plus a round icon button.
//
//  Colour: solid/brand/glassProminent foregrounds use `catbirdTheme.onAccent` for WCAG AA
//  contrast across all 7 palettes × 3 modes. `.primary` fills with the active tint;
//  `.brand` is the opt-in hero gradient; `.glass` and `.glassProminent` delegate to
//  `.catbirdGlass(...)` so Liquid Glass, Reduce Transparency, and OLED True Black stay consistent.
//  Hit targets are always >= 44x44. CatbirdIconButton scales its glyph and circle with Dynamic Type.
//

import SwiftUI

enum CatbirdButtonKind: CaseIterable, Sendable {
  /// Solid tint fill, contrast-safe `onAccent` label. Same look at every size.
  case primary
  /// Opt-in hero button: brand gradient (accent toward palette partner), `onAccent` label.
  case brand
  case tonal
  /// Hairline stroke, primary label.
  case outline
  /// Hairline stroke, secondary label. Disabled-looking state that is not dimmed (e.g. Blocked).
  case muted
  case quiet
  case destructive
  /// Liquid Glass capsule, primary label. For secondary actions over imagery.
  /// Falls back cleanly pre-iOS 26, under Reduce Transparency, and in OLED True Black.
  case glass
  /// Liquid Glass tinted with active `accentChrome`, `onAccent` label. For the main action over imagery.
  /// Falls back cleanly pre-iOS 26, under Reduce Transparency, and in OLED True Black.
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
    case .sm: return .footnote.weight(.semibold)
    case .md: return .subheadline.weight(.semibold)
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
  var haptic = true

  func makeBody(configuration: Configuration) -> some View {
    CatbirdButtonBody(
      configuration: configuration,
      kind: kind,
      size: size,
      fullWidth: fullWidth,
      isLoading: isLoading,
      haptic: haptic
    )
  }
}

extension ButtonStyle where Self == CatbirdButtonStyle {
  static func catbird(
    _ kind: CatbirdButtonKind = .primary,
    size: CatbirdButtonSize = .md,
    fullWidth: Bool = false,
    isLoading: Bool = false,
    haptic: Bool = true
  ) -> CatbirdButtonStyle {
    CatbirdButtonStyle(
      kind: kind,
      size: size,
      fullWidth: fullWidth,
      isLoading: isLoading,
      haptic: haptic
    )
  }
}

private struct CatbirdButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let kind: CatbirdButtonKind
  let size: CatbirdButtonSize
  let fullWidth: Bool
  let isLoading: Bool
  let haptic: Bool

  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.catbirdTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast

  private var increased: Bool { theme.isHighContrast || contrast == .increased }

  private var foreground: AnyShapeStyle {
    switch kind {
    case .primary, .brand, .glassProminent: return AnyShapeStyle(theme.onAccent)
    case .tonal, .quiet: return AnyShapeStyle(theme.accentText)
    case .outline, .glass: return AnyShapeStyle(theme.text(.primary))
    case .muted: return AnyShapeStyle(theme.text(.secondary))
    case .destructive: return AnyShapeStyle(theme.semantic(.danger))
    }
  }

  /// Never the tint shape style itself: a tint that resolves to the tint recurses forever.
  private var spinnerTint: AnyShapeStyle? {
    foreground
  }

  var body: some View {
    let pressed = configuration.isPressed
    configuration.label
      .appFont(size.textRole)
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
      .modifier(CatbirdButtonGlassChrome(kind: kind))
      .overlay {
        if kind == .outline || kind == .muted {
          Capsule(style: .continuous)
            .strokeBorder(
              theme.border(increased ? .prominent : .subtle),
              lineWidth: increased ? 1.5 : 1
            )
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
      .catbirdAnimation(MotionIntent.instant, value: pressed)
      .onChange(of: pressed) { _, nowPressed in
        if nowPressed && haptic && isEnabled && !isLoading {
          Self.triggerTapHaptic()
        }
      }
  }

  @ViewBuilder private var background: some View {
    let shape = Capsule(style: .continuous)
    let tonal = increased ? 0.22 : 0.14
    switch kind {
    case .primary: shape.fill(theme.accentChrome)
    case .brand: shape.fill(BrandGradient.current(theme: theme))
    case .tonal: shape.fill(theme.accentChrome.opacity(tonal))
    case .destructive: shape.fill(theme.semantic(.danger).opacity(tonal))
    case .outline, .muted, .quiet, .glass, .glassProminent: Color.clear
    }
  }

  private static func triggerTapHaptic() {
    #if os(iOS)
    PlatformHaptics.light()
    #endif
  }
}

/// Routes `.glass` and `.glassProminent` through the unified `.catbirdGlass(...)` pipeline.
private struct CatbirdButtonGlassChrome: ViewModifier {
  let kind: CatbirdButtonKind

  @ViewBuilder func body(content: Content) -> some View {
    switch kind {
    case .glass:
      content.catbirdGlass(.regular, in: Capsule(style: .continuous), interactive: true, tinted: false)
    case .glassProminent:
      content.catbirdGlass(.prominent, in: Capsule(style: .continuous), interactive: true, tinted: true)
    default:
      content
    }
  }
}

// MARK: - Icon button

enum CatbirdIconButtonStyle: Sendable {
  case tonal, quiet
  /// Liquid Glass via `.catbirdGlass` (handles iOS 26, pre-26, Reduce Transparency, and True Black).
  case glass
}

/// Round SF Symbol button. Visual 32/40/48 (scaled with Dynamic Type, max 1.5x), 44pt minimum hit target.
struct CatbirdIconButton: View {
  let systemImage: String
  var label: Text
  var size: CatbirdButtonSize = .md
  var style: CatbirdIconButtonStyle = .tonal
  var haptic: Bool = true
  var action: () -> Void

  @Environment(\.isEnabled) private var isEnabled
  @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

  init(
    systemImage: String,
    label: LocalizedStringKey,
    size: CatbirdButtonSize = .md,
    style: CatbirdIconButtonStyle = .tonal,
    haptic: Bool = true,
    action: @escaping () -> Void
  ) {
    self.init(
      systemImage: systemImage,
      label: Text(label),
      size: size,
      style: style,
      haptic: haptic,
      action: action
    )
  }

  init(
    systemImage: String,
    label: Text,
    size: CatbirdButtonSize = .md,
    style: CatbirdIconButtonStyle = .tonal,
    haptic: Bool = true,
    action: @escaping () -> Void
  ) {
    self.systemImage = systemImage
    self.label = label
    self.size = size
    self.style = style
    self.haptic = haptic
    self.action = action
  }

  private var glyphSize: CGFloat {
    switch size {
    case .sm: return IconSize.inline
    case .md: return 17
    case .lg: return IconSize.md
    }
  }

  private var side: CGFloat { size.height * min(scale, 1.5) }

  var body: some View {
    Button {
      if self.haptic {
        Self.triggerTapHaptic()
      }
      self.action()
    } label: {
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

  private static func triggerTapHaptic() {
    #if os(iOS)
    PlatformHaptics.light()
    #endif
  }
}

private struct IconChrome: ViewModifier {
  let style: CatbirdIconButtonStyle
  @Environment(\.catbirdTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast

  private var increased: Bool { theme.isHighContrast || contrast == .increased }

  @ViewBuilder func body(content: Content) -> some View {
    switch style {
    case .tonal:
      content.background(Circle().fill(TintShapeStyle().opacity(increased ? 0.22 : 0.14)))
    case .quiet:
      content
    case .glass:
      content.catbirdGlass(.regular, in: Circle(), interactive: true, tinted: false)
    }
  }
}

private struct CatbirdIconPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .catbirdAnimation(MotionIntent.instant, value: configuration.isPressed)
  }
}

#Preview("Buttons") {
  VStack(alignment: .leading, spacing: Space.md) {
    ForEach(CatbirdButtonKind.allCases, id: \.self) { kind in
      HStack {
        ForEach(CatbirdButtonSize.allCases, id: \.self) { size in
          Button {} label: { Text(verbatim: "Label") }.buttonStyle(.catbird(kind, size: size))
        }
      }
    }
    Button {} label: { Text(verbatim: "Continue") }
      .buttonStyle(.catbird(.brand, size: .lg, fullWidth: true))
    Button {} label: { Text(verbatim: "Loading") }
      .buttonStyle(.catbird(.primary, size: .md, isLoading: true))
    HStack {
      CatbirdIconButton(systemImage: "plus", label: Text(verbatim: "Add"), size: .sm) {}
      CatbirdIconButton(systemImage: "plus", label: Text(verbatim: "Add"), size: .md, style: .glass) {}
      CatbirdIconButton(systemImage: "plus", label: Text(verbatim: "Add"), size: .lg, style: .quiet) {}
    }
  }
  .padding(Space.screenMargin)
}
