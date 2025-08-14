//
//  GlassCompatibility.swift
//  Catbird
//
//  Created by Claude Code on 8/13/25.
//

import SwiftUI

public extension View {
    
    @ViewBuilder
    func adaptiveGlassEffect(
        style: AdaptiveGlassStyle = .regular,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            let glassStyle: Glass = {
                if let tintColor = style.tintColor {
                    return .regular.tint(tintColor)
                } else {
                    return .regular
                }
            }()
            
            if interactive {
                self.glassEffect(glassStyle.interactive())
            } else {
                self.glassEffect(glassStyle)
            }
        } else {
            self.adaptiveGlassFallback(style: style, interactive: interactive)
        }
    }
    
    @ViewBuilder
    func adaptiveGlassEffect<S: Shape>(
        style: AdaptiveGlassStyle = .regular,
        in shape: S,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            let glassStyle: Glass = {
                if let tintColor = style.tintColor {
                    return .regular.tint(tintColor)
                } else {
                    return .regular
                }
            }()
            
            if interactive {
                self.glassEffect(glassStyle.interactive(), in: shape)
            } else {
                self.glassEffect(glassStyle, in: shape)
            }
        } else {
            self.adaptiveGlassFallback(style: style, interactive: interactive, shape: AnyShape(shape))
        }
    }
    
    @ViewBuilder
    func adaptiveGlassContainer<Content: View>(
        spacing: CGFloat = 8,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            VStack(spacing: spacing) {
                content()
            }
        }
    }
    
    /// Glass morphing support for all iOS versions (no-op on iOS 25 and earlier)
    @ViewBuilder
    func catbirdGlassMorphing<ID: Hashable>(
        id: ID,
        namespace: Namespace.ID
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            // On iOS 25 and earlier, just return the view without morphing
            self
        }
    }
    
    private func adaptiveGlassFallback(
        style: AdaptiveGlassStyle,
        interactive: Bool,
        shape: AnyShape? = nil
    ) -> some View {
        let baseView = self
            .background(style.fallbackMaterial, in: shape ?? AnyShape(Capsule()))
            .overlay(
                LinearGradient(
                    colors: style.fallbackOverlayColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .opacity(0.3)
            )
            .overlay(
                (shape ?? AnyShape(Capsule()))
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
        
        if interactive {
            return AnyView(
                baseView
                    .scaleEffect(1.0)
                    .animation(.easeInOut(duration: 0.1), value: interactive)
            )
        } else {
            return AnyView(baseView)
        }
    }
}

public enum AdaptiveGlassStyle {
    case regular
    case prominent
    case subtle
    case tinted(Color)
    
    var tintColor: Color? {
        switch self {
        case .regular, .prominent, .subtle:
            return nil
        case .tinted(let color):
            return color
        }
    }
    
    var fallbackMaterial: Material {
        switch self {
        case .regular:
            return .regularMaterial
        case .prominent:
            return .thickMaterial
        case .subtle:
            return .ultraThinMaterial
        case .tinted(_):
            return .regularMaterial
        }
    }
    
    var fallbackOverlayColors: [Color] {
        switch self {
        case .regular:
            return [.white.opacity(0.2), .clear, .black.opacity(0.05)]
        case .prominent:
            return [.white.opacity(0.3), .clear, .black.opacity(0.1)]
        case .subtle:
            return [.white.opacity(0.1), .clear]
        case .tinted(let color):
            return [color.opacity(0.2), .clear, color.opacity(0.1)]
        }
    }
}

private struct AnyShape: Shape {
    private let _path: @Sendable (CGRect) -> Path
    
    init<S: Shape>(_ shape: S) {
        _path = { rect in
            shape.path(in: rect)
        }
    }
    
    func path(in rect: CGRect) -> Path {
        _path(rect)
    }
}
