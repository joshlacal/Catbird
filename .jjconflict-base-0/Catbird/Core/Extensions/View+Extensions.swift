import SwiftUI

// MARK: - Animation Extensions for Accessibility

extension View {
    /// Apply animation that respects the user's reduce motion preference
    func accessibleAnimation<V: Equatable>(_ animation: Animation?, value: V, appState: AppState?) -> some View {
        let shouldReduceMotion = appState?.appSettings.reduceMotion ?? false
        let prefersCrossfade = appState?.appSettings.prefersCrossfade ?? false
        
        let finalAnimation: Animation? = {
            if shouldReduceMotion {
                return prefersCrossfade ? .easeInOut(duration: 0.2) : nil
            }
            return animation
        }()
        
        return self.animation(finalAnimation, value: value)
    }
    
    /// Apply withAnimation that respects the user's reduce motion preference
    func accessibleWithAnimation<Result>(_ animation: Animation?, appState: AppState?, _ body: () throws -> Result) rethrows -> Result {
        let shouldReduceMotion = appState?.appSettings.reduceMotion ?? false
        let prefersCrossfade = appState?.appSettings.prefersCrossfade ?? false
        
        let finalAnimation: Animation? = {
            if shouldReduceMotion {
                return prefersCrossfade ? .easeInOut(duration: 0.2) : nil
            }
            return animation
        }()
        
        return try withAnimation(finalAnimation, body)
    }
    
    /// Apply transition that respects the user's reduce motion preference
    func accessibleTransition(_ transition: AnyTransition, appState: AppState?) -> some View {
        let shouldReduceMotion = appState?.appSettings.reduceMotion ?? false
        let prefersCrossfade = appState?.appSettings.prefersCrossfade ?? false
        
        let finalTransition: AnyTransition = {
            if shouldReduceMotion {
                return prefersCrossfade ? .opacity : .identity
            }
            return transition
        }()
        
        return self.transition(finalTransition)
    }
    
    /// Apply scale animation that respects reduce motion
    @ViewBuilder
    func accessibleScaleEffect(_ scale: CGFloat, anchor: UnitPoint = .center, appState: AppState?) -> some View {
        let shouldReduceMotion = appState?.appSettings.reduceMotion ?? false

        if shouldReduceMotion {
            // Use subtle opacity change instead of scale
            self.opacity(scale > 1.0 ? 0.8 : 1.0)
        } else {
            self.scaleEffect(scale, anchor: anchor)
        }
    }
    
    /// Apply rotation animation that respects reduce motion
    @ViewBuilder
    func accessibleRotationEffect(_ angle: Angle, anchor: UnitPoint = .center, appState: AppState?) -> some View {
        let shouldReduceMotion = appState?.appSettings.reduceMotion ?? false

        if shouldReduceMotion {
            // Skip rotation entirely when reduce motion is on
            self
        } else {
            self.rotationEffect(angle, anchor: anchor)
        }
    }
    
    /// Apply offset animation that respects reduce motion
    func accessibleOffset(x: CGFloat = 0, y: CGFloat = 0, appState: AppState?) -> some View {
        let shouldReduceMotion = appState?.appSettings.reduceMotion ?? false
        let prefersCrossfade = appState?.appSettings.prefersCrossfade ?? false
        
        if shouldReduceMotion && !prefersCrossfade {
            // Reduce offset to minimal movement
            return self.offset(x: x * 0.2, y: y * 0.2)
        } else {
            return self.offset(x: x, y: y)
        }
    }
}

extension View {
    func globalBackgroundColor(_ color: Color) -> some View {
        self.background(color.edgesIgnoringSafeArea(.all))
    }
    
    /// Shimmering effect for loading states
    func shimmering() -> some View {
        self
            .redacted(reason: .placeholder)
            .overlay(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.clear,
                        Color.white.opacity(0.3),
                        Color.clear
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .mask(self)
            )
    }
}

// MARK: - Display Scale Extensions

struct DisplayScaleModifier: ViewModifier {
    let scale: CGFloat
    
    func body(content: Content) -> some View {
        content.scaleEffect(scale)
    }
}

extension View {
    func displayScale(_ scale: CGFloat) -> some View {
        self.modifier(DisplayScaleModifier(scale: scale))
    }
    
    func appDisplayScale(appState: AppState?) -> some View {
        let scale = CGFloat(appState?.appSettings.displayScale ?? 1.0)
        return self.displayScale(scale)
    }
}

extension Color {
    /// Theme-aware primary background that properly handles dim mode
    static func primaryBackground(themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        return Color.dynamicBackground(themeManager, currentScheme: currentScheme)
    }
    
    /// Theme-aware secondary background that properly handles dim mode
    static func secondaryBackground(themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        return Color.dynamicSecondaryBackground(themeManager, currentScheme: currentScheme)
    }
}
