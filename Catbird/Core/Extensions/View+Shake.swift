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
    @ViewBuilder
    func shake(animatableParameter: Bool, intensity: CGFloat = 5, cycles: CGFloat = 4, duration: CGFloat = 0.6) -> some View {
        modifier(ShakeEffect(animating: animatableParameter, intensity: intensity, cycles: cycles, duration: duration))
    }
}

/// A view modifier that applies a shake animation
struct ShakeEffect: ViewModifier {
    // Animation state
    var animating: Bool
    var intensity: CGFloat
    var cycles: CGFloat
    var duration: CGFloat
    
    // Animatable binding for smooth transitions
    @State private var animatableParameter: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .offset(x: animatableParameter)
            .onChange(of: animating) { _, newValue in
                guard newValue else { return }
                
                withAnimation(.interactiveSpring(response: duration, dampingFraction: 0.6)) {
                    // Start with a bit of the animation
                    animatableParameter = intensity * 0.5
                } completion: {
                    // Quick motion in opposite direction
                    withAnimation(.bouncy(duration: duration, extraBounce: 0.1)) {
                        animatableParameter = -intensity
                    } completion: {
                        // Settling animation
                        withAnimation(.interpolatingSpring(mass: 1.0, stiffness: 100, damping: 10)) {
                            animatableParameter = 0
                        }
                    }
                }
            }
    }
}
