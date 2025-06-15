import SwiftUI
import Foundation

/// Manager for handling motion reduction and animation preferences
struct MotionManager {
    
    /// Check if motion should be reduced based on user settings
    static func shouldReduceMotion(appSettings: AppSettings) -> Bool {
        return appSettings.reduceMotion
    }
    
    /// Check if crossfade transitions should be preferred
    static func shouldUseCrossfade(appSettings: AppSettings) -> Bool {
        return appSettings.reduceMotion && appSettings.prefersCrossfade
    }
    
    /// Get appropriate animation for user preferences
    static func animation(for appSettings: AppSettings, default defaultAnimation: Animation = .easeInOut(duration: 0.3)) -> Animation? {
        if shouldReduceMotion(appSettings: appSettings) {
            return nil // No animation
        }
        return defaultAnimation
    }
    
    /// Get appropriate spring animation for user preferences
    static func springAnimation(for appSettings: AppSettings, duration: Double = 0.3, bounce: Double = 0.0) -> Animation? {
        if shouldReduceMotion(appSettings: appSettings) {
            return nil // No animation
        }
        return .spring(duration: duration, bounce: bounce)
    }
    
    /// Get appropriate transition for user preferences
    static func transition(for appSettings: AppSettings, default defaultTransition: AnyTransition = .opacity) -> AnyTransition {
        if shouldUseCrossfade(appSettings: appSettings) {
            return .opacity
        } else if shouldReduceMotion(appSettings: appSettings) {
            return .identity // No transition
        }
        return defaultTransition
    }
    
    /// Execute animation block only if motion is allowed
    static func withAnimation<Result>(
        for appSettings: AppSettings,
        animation: Animation? = .easeInOut(duration: 0.3),
        _ body: () throws -> Result
    ) rethrows -> Result {
        if shouldReduceMotion(appSettings: appSettings) {
            return try body()
        } else {
            return try SwiftUI.withAnimation(animation, body)
        }
    }
    
    /// Execute spring animation block only if motion is allowed
    static func withSpringAnimation<Result>(
        for appSettings: AppSettings,
        duration: Double = 0.3,
        bounce: Double = 0.0,
        _ body: () throws -> Result
    ) rethrows -> Result {
        if shouldReduceMotion(appSettings: appSettings) {
            return try body()
        } else {
            return try SwiftUI.withAnimation(.spring(duration: duration, bounce: bounce), body)
        }
    }
}

/// View modifier for applying motion-aware animations
struct MotionAwareAnimation<V: Equatable>: ViewModifier {
    let appSettings: AppSettings
    let animation: Animation
    let value: V
    
    func body(content: Content) -> some View {
        if MotionManager.shouldReduceMotion(appSettings: appSettings) {
            content
        } else {
            content.animation(animation, value: value)
        }
    }
}

/// View modifier for applying motion-aware transitions
struct MotionAwareTransition: ViewModifier {
    let appSettings: AppSettings
    let transition: AnyTransition
    
    func body(content: Content) -> some View {
        content.transition(MotionManager.transition(for: appSettings, default: transition))
    }
}

/// Extensions for easier usage
extension View {
    /// Apply animation only if motion reduction is disabled
    func motionAwareAnimation<V: Equatable>(
        _ animation: Animation,
        value: V,
        appSettings: AppSettings
    ) -> some View {
        modifier(MotionAwareAnimation(appSettings: appSettings, animation: animation, value: value))
    }
    
    /// Apply transition based on motion preferences
    func motionAwareTransition(
        _ transition: AnyTransition,
        appSettings: AppSettings
    ) -> some View {
        modifier(MotionAwareTransition(appSettings: appSettings, transition: transition))
    }
}
