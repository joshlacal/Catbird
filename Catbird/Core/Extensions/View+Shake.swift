import SwiftUI

// A modern shake effect modifier for SwiftUI views
// Adds a more interactive and responsive visual feedback for users
extension View {
    /// Applies a shake animation to a view when triggered
    /// - Parameters:
    ///   - animatableParameter: The parameter to trigger animation when changed
    ///   - intensity: How strong the shake should be (default: 5)
    ///   - cycles: How many times to shake back and forth (default: 4)
    ///   - duration: How long the animation lasts (default: 0.6 seconds)
    ///   - appSettings: App settings to check motion reduction preferences
    @ViewBuilder
    func shake(animatableParameter: Bool, intensity: CGFloat = 5, cycles: CGFloat = 4, duration: CGFloat = 0.6, appSettings: AppSettings) -> some View {
        modifier(ShakeEffect(animating: animatableParameter, intensity: intensity, cycles: cycles, duration: duration, appSettings: appSettings))
    }
}

/// A view modifier that applies a shake animation
struct ShakeEffect: ViewModifier {
    // Animation state
    var animating: Bool
    var intensity: CGFloat
    var cycles: CGFloat
    var duration: CGFloat
    var appSettings: AppSettings
    
    // Animatable binding for smooth transitions
    @State private var animatableParameter: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .offset(x: animatableParameter)
            .onChange(of: animating) { _, newValue in
                guard newValue else { return }
                
                // Skip animation if motion reduction is enabled or shake is disabled
                if MotionManager.shouldReduceMotion(appSettings: appSettings) || !appSettings.shakeToUndo {
                    return
                }
                
                // Use Task for sequential animations since MotionManager doesn't support completion blocks
                Task { @MainActor in
                    MotionManager.withAnimation(for: appSettings, animation: .interactiveSpring(response: duration * 0.3, dampingFraction: 0.6)) {
                        animatableParameter = intensity * 0.5
                    }
                    
                    try? await Task.sleep(nanoseconds: UInt64(duration * 0.3 * 1_000_000_000))
                    
                    MotionManager.withAnimation(for: appSettings, animation: .bouncy(duration: duration * 0.4, extraBounce: 0.1)) {
                        animatableParameter = -intensity
                    }
                    
                    try? await Task.sleep(nanoseconds: UInt64(duration * 0.4 * 1_000_000_000))
                    
                    MotionManager.withAnimation(for: appSettings, animation: .interpolatingSpring(mass: 1.0, stiffness: 100, damping: 10)) {
                        animatableParameter = 0
                    }
                }
            }
    }
}
