//
//  AdaptiveGlassEffect.swift
//  Catbird
//
//  Created by Claude Code on 8/14/25.
//

import SwiftUI

// MARK: - Adaptive Glass Effect Style

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
                ZStack {
                    style.fallbackMaterial
                    if let tint = style.fallbackTintColor {
                        tint
                    }
                }
                .clipShape(shape)
            }
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}