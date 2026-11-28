//
//  AdaptiveGlassEffect.swift
//  Catbird
//
//  Unified Liquid Glass + material + accessibility + True-Black opaque surface modifier.
//  Honors iOS/macOS 26 Liquid Glass, pre-26 material fallback, `accessibilityReduceTransparency`,
//  True-Black opaque panels (`docs/brand/06-materials.md`), and the active `CatbirdThemeColors`
//  accent without hardcoded `.blue` or static `Color.accentColor`.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Unified Glass Style

public enum CatbirdGlassStyle: CaseIterable, Sendable, Hashable {
  case regular
  case clear
  case prominent
}

// MARK: - Unified Catbird Glass Modifier

public extension View {
  /// Apply Catbird's unified Liquid Glass surface inside a continuous capsule.
  func catbirdGlass(
    _ style: CatbirdGlassStyle = .regular,
    interactive: Bool = false,
    tinted: Bool = false
  ) -> some View {
    modifier(
      CatbirdGlassModifier(
        style: style,
        shape: Capsule(style: .continuous),
        interactive: interactive,
        tinted: tinted
      )
    )
  }

  /// Apply Catbird's unified Liquid Glass surface inside an explicit shape.
  func catbirdGlass<S: Shape>(
    _ style: CatbirdGlassStyle = .regular,
    in shape: S,
    interactive: Bool = false,
    tinted: Bool = false
  ) -> some View {
    modifier(
      CatbirdGlassModifier(
        style: style,
        shape: shape,
        interactive: interactive,
        tinted: tinted
      )
    )
  }
}

private struct CatbirdGlassModifier<S: Shape>: ViewModifier {
  let style: CatbirdGlassStyle
  let shape: S
  let interactive: Bool
  let tinted: Bool

  @Environment(\.catbirdTheme) private var theme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private var usesTint: Bool {
    tinted || style == .prominent
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if reduceTransparency || theme.isTrueBlack {
      opaqueSurface(content)
    } else {
      translucentSurface(content)
    }
  }

  @ViewBuilder
  private func opaqueSurface(_ content: Content) -> some View {
    if usesTint {
      content
        .background {
          shape.fill(theme.accentChrome)
        }
        .overlay {
          if theme.isHighContrast {
            shape
              .stroke(theme.border(.prominent), lineWidth: 3)
              .clipShape(shape)
          }
        }
    } else {
      content
        .background {
          shape.fill(theme.surface(.elevated))
        }
        .overlay {
          shape
            .stroke(
              theme.border(.prominent),
              lineWidth: theme.isHighContrast ? 3 : 2
            )
            .clipShape(shape)
        }
    }
  }

  @ViewBuilder
  private func translucentSurface(_ content: Content) -> some View {
    #if compiler(>=6.2)
    if #available(iOS 26.0, macOS 26.0, *) {
      nativeGlassSurface(content)
    } else {
      legacyMaterialSurface(content)
    }
    #else
    legacyMaterialSurface(content)
    #endif
  }

  #if compiler(>=6.2)
  @available(iOS 26.0, macOS 26.0, *)
  private func nativeGlassSurface(_ content: Content) -> some View {
    let baseGlass: Glass = {
      switch style {
      case .regular:
        return usesTint ? Glass.regular.tint(theme.accentChrome) : Glass.regular
      case .clear:
        return usesTint ? Glass.clear.tint(theme.accentChrome) : Glass.clear
      case .prominent:
        return Glass.regular.tint(theme.accentChrome)
      }
    }()
    let resolvedGlass = interactive ? baseGlass.interactive() : baseGlass
    return content.glassEffect(resolvedGlass, in: shape)
  }
  #endif

  @ViewBuilder
  private func legacyMaterialSurface(_ content: Content) -> some View {
    if style == .prominent {
      content
        .background {
          shape.fill(theme.accentChrome)
        }
    } else {
      let material: Material = style == .clear ? .ultraThinMaterial : .regularMaterial
      content
        .background {
          shape
            .fill(material)
            .overlay {
              if usesTint {
                shape.fill(theme.accentChrome.opacity(0.28))
              }
            }
        }
        .overlay {
          shape
            .stroke(theme.border(.subtle), lineWidth: 2)
            .clipShape(shape)
        }
    }
  }
}

// MARK: - Deprecated Legacy Wrappers

@available(*, deprecated, message: "Use CatbirdGlassStyle and .catbirdGlass(...)")
public enum AdaptiveGlassStyle: Sendable, Hashable {
  case regular
  case secondary
  case accentTinted

  fileprivate var mappedStyle: CatbirdGlassStyle {
    .regular
  }

  fileprivate var mappedTinted: Bool {
    self == .accentTinted
  }
}

public extension View {
  @available(*, deprecated, message: "Use .catbirdGlass(...)")
  func adaptiveGlassEffect(
    style: AdaptiveGlassStyle = .regular,
    interactive: Bool = false
  ) -> some View {
    catbirdGlass(
      style.mappedStyle,
      in: Radius.md.shape,
      interactive: interactive,
      tinted: style.mappedTinted
    )
  }

  @available(*, deprecated, message: "Use .catbirdGlass(...)")
  func adaptiveGlassEffect<S: Shape>(
    style: AdaptiveGlassStyle = .regular,
    in shape: S,
    interactive: Bool = false
  ) -> some View {
    catbirdGlass(
      style.mappedStyle,
      in: shape,
      interactive: interactive,
      tinted: style.mappedTinted
    )
  }
}

// MARK: - Fallback Compatibility Shims for Xcode 16 / Swift < 6.2

#if !compiler(>=6.2)

public struct Glass: Sendable {
  public static let regular = Glass()
  public static let clear = Glass()
  public func tint(_ color: Color) -> Glass { self }
  public func interactive() -> Glass { self }
}

public struct GlassEffectContainer<Content: View>: View {
  let spacing: CGFloat?
  @ViewBuilder let content: () -> Content

  public init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
    self.spacing = spacing
    self.content = content
  }

  public var body: some View {
    HStack(spacing: spacing) {
      content()
    }
  }
}

public struct GlassEffectTransition {
  public static let matchedGeometry = GlassEffectTransition()
}

public struct ConcentricCornerRadius: Sendable {
  public init() {}
  public static func fixed(_ value: CGFloat) -> ConcentricCornerRadius { ConcentricCornerRadius() }
}

public struct ConcentricCorners: Sendable {
  public init() {}
  public static func concentric(minimum: ConcentricCornerRadius) -> ConcentricCorners { ConcentricCorners() }
  public static func fixed(_ value: CGFloat) -> ConcentricCorners { ConcentricCorners() }
}

public struct ConcentricRectangle: Shape, Sendable {
  public init() {}
  public init(corners: ConcentricCorners = ConcentricCorners(), isUniform: Bool = true) {}
  public func path(in rect: CGRect) -> Path {
    Radius.xl.shape.path(in: rect)
  }
}

#if os(iOS)
public class UIGlassEffect: UIVisualEffect {
  public var tintColor: UIColor?
  public var isInteractive: Bool = false
  public override init() { super.init() }
  public required init?(coder: NSCoder) { super.init(coder: coder) }
}
#endif

public extension AttributedString {
  func index(_ index: AttributedString.Index, offsetByCharacters offset: Int) -> AttributedString.Index {
    self.characters.index(index, offsetBy: offset)
  }
}

public struct AttributedTextSelection: Sendable, Equatable {
  public struct RangeSet: Sendable, Equatable {
    public var ranges: [Range<AttributedString.Index>]
    public init(ranges: [Range<AttributedString.Index>] = []) {
      self.ranges = ranges
    }
  }

  public enum SelectionIndices: Sendable, Equatable {
    case insertionPoint
    case ranges(RangeSet)
  }

  public var range: NSRange?

  public init() {
    self.range = nil
  }

  public init(range: NSRange) {
    self.range = range
  }

  public func indices(in text: AttributedString) -> SelectionIndices {
    if let range = range,
      let strRange = Range(range, in: String(text.characters)),
      let start = AttributedString.Index(strRange.lowerBound, within: text),
      let end = AttributedString.Index(strRange.upperBound, within: text) {
      return .ranges(RangeSet(ranges: [start..<end]))
    }
    return .insertionPoint
  }
}

public extension TextEditor {
  init(text: Binding<AttributedString>, selection: Binding<AttributedTextSelection>) {
    self.init(text: Binding(
      get: { String(text.wrappedValue.characters) },
      set: { text.wrappedValue = AttributedString($0) }
    ))
  }
}

public extension View {
  @ViewBuilder
  func glassEffect() -> some View {
    self
  }

  @ViewBuilder
  func glassEffect(_ style: Glass) -> some View {
    self
  }

  @ViewBuilder
  func glassEffect<S: Shape>(_ style: Glass, in shape: S) -> some View {
    self
  }

  @ViewBuilder
  func glassEffect<S: Shape>(in shape: S) -> some View {
    self
  }

  @ViewBuilder
  func glassEffectUnion(id: String, namespace: Namespace.ID) -> some View {
    self
  }

  @ViewBuilder
  func glassEffectID(_ id: String, in namespace: Namespace.ID) -> some View {
    self
  }

  @ViewBuilder
  func glassEffectTransition(_ transition: GlassEffectTransition) -> some View {
    self
  }
}

#endif
