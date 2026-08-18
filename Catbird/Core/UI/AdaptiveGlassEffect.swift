//
//  AdaptiveGlassEffect.swift
//  Catbird
//
//  Created by Claude Code on 8/14/25.
//

import SwiftUI

#if compiler(>=6.2)

// MARK: - Adaptive Glass Effect Style (iOS 26+ / Swift 6.2+)

@available(macOS 26.0, *)
public enum AdaptiveGlassStyle {
    case regular
    case secondary
    case accentTinted
    
    @available(iOS 26.0, *)
    var nativeGlassStyle: Glass {
        switch self {
        case .regular:
            return .regular
        case .secondary:
            return .regular.tint(.secondary)
        case .accentTinted:
            return .regular.tint(.blue)
        }
    }
    
    var fallbackMaterial: Material {
        switch self {
        case .regular:
            return .ultraThinMaterial
        case .secondary:
            return .thinMaterial
        case .accentTinted:
            return .ultraThinMaterial
        }
    }
    
    var fallbackTintColor: Color? {
        switch self {
        case .regular:
            return nil
        case .secondary:
            return .secondary.opacity(0.3)
        case .accentTinted:
            return .blue.opacity(0.3)
        }
    }
}

// MARK: - Adaptive Glass Effect Extensions

@available(macOS 26.0, *)
public extension View {
    
    @ViewBuilder
    func adaptiveGlassEffect(
        style: AdaptiveGlassStyle = .regular,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            let glassStyle = interactive ? style.nativeGlassStyle.interactive() : style.nativeGlassStyle
            self.glassEffect(glassStyle)
        } else {
            self.adaptiveGlassFallback(style: style)
        }
    }
    
    @ViewBuilder
    func adaptiveGlassEffect<S: Shape>(
        style: AdaptiveGlassStyle = .regular,
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            let glassStyle = interactive ? style.nativeGlassStyle.interactive() : style.nativeGlassStyle
            self.glassEffect(glassStyle, in: shape)
        } else {
            self.adaptiveGlassFallback(style: style, shape: shape)
        }
    }
    
    @ViewBuilder
    private func adaptiveGlassFallback(
        style: AdaptiveGlassStyle
    ) -> some View {
        self
            .background(style.fallbackMaterial)
            .overlay {
                if let tint = style.fallbackTintColor {
                    tint
                }
            }
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
    
    @ViewBuilder
    private func adaptiveGlassFallback<S: Shape>(
        style: AdaptiveGlassStyle,
        shape: S
    ) -> some View {
        self
            .background {
                Rectangle()
                    .fill(style.fallbackMaterial)
                    .overlay {
                        if let tint = style.fallbackTintColor {
                            Rectangle()
                                .fill(tint)
                        }
                    }
                    .clipShape(shape)
            }
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}

#else

// MARK: - Fallback Compatibility Shims for Xcode 16 / Swift < 6.2

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

public enum AdaptiveGlassStyle {
    case regular
    case secondary
    case accentTinted
    
    var fallbackMaterial: Material {
        switch self {
        case .regular:
            return .ultraThinMaterial
        case .secondary:
            return .thinMaterial
        case .accentTinted:
            return .ultraThinMaterial
        }
    }
    
    var fallbackTintColor: Color? {
        switch self {
        case .regular:
            return nil
        case .secondary:
            return .secondary.opacity(0.3)
        case .accentTinted:
            return .blue.opacity(0.3)
        }
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

    @ViewBuilder
    func adaptiveGlassEffect(
        style: AdaptiveGlassStyle = .regular,
        interactive: Bool = false
    ) -> some View {
        self.background(style.fallbackMaterial)
            .overlay {
                if let tint = style.fallbackTintColor {
                    tint
                }
            }
    }

    @ViewBuilder
    func adaptiveGlassEffect<S: Shape>(
        style: AdaptiveGlassStyle = .regular,
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        self.background {
            Rectangle()
                .fill(style.fallbackMaterial)
                .overlay {
                    if let tint = style.fallbackTintColor {
                        Rectangle().fill(tint)
                    }
                }
                .clipShape(shape)
        }
    }
}

#endif
