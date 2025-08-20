//
//  PlatformHaptics.swift
//  Catbird
//
//  Created by Claude on 8/19/25.
//

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import OSLog

private let hapticsLogger = Logger(subsystem: "blue.catbird", category: "PlatformHaptics")

/// Cross-platform haptic feedback system
@MainActor
public struct PlatformHaptics {
    
    // MARK: - Haptic Feedback Types
    
    /// Impact feedback intensities
    public enum ImpactIntensity {
        case light
        case medium
        case heavy
        case soft      // iOS 17+
        case rigid     // iOS 17+
    }
    
    /// Notification feedback types
    public enum NotificationType {
        case success
        case warning
        case error
    }
    
    /// Selection feedback for UI interactions
    public enum SelectionType {
        case selection
    }
    
    // MARK: - Impact Feedback
    
    /// Provide impact haptic feedback
    public static func impact(_ intensity: ImpactIntensity = .medium) {
        #if os(iOS)
        Task { @MainActor in
            let generator: UIImpactFeedbackGenerator
            
            switch intensity {
            case .light:
                generator = UIImpactFeedbackGenerator(style: .light)
            case .medium:
                generator = UIImpactFeedbackGenerator(style: .medium)
            case .heavy:
                generator = UIImpactFeedbackGenerator(style: .heavy)
            case .soft:
                if #available(iOS 17.0, *) {
                    generator = UIImpactFeedbackGenerator(style: .soft)
                } else {
                    generator = UIImpactFeedbackGenerator(style: .light)
                }
            case .rigid:
                if #available(iOS 17.0, *) {
                    generator = UIImpactFeedbackGenerator(style: .rigid)
                } else {
                    generator = UIImpactFeedbackGenerator(style: .heavy)
                }
            }
            
            generator.prepare()
            generator.impactOccurred()
            
            hapticsLogger.debug("Impact haptic triggered: \(String(describing: intensity))")
        }
        #elseif os(macOS)
        // macOS fallback: play system sound
        switch intensity {
        case .light, .soft:
            NSSound(named: "Funk")?.play()
        case .medium:
            NSSound(named: "Ping")?.play()
        case .heavy, .rigid:
            NSSound(named: "Purr")?.play()
        }
        
        hapticsLogger.debug("macOS sound feedback for impact: \(String(describing: intensity))")
        #endif
    }
    
    /// Convenience methods for common impact types
    public static func light() {
        impact(.light)
    }
    
    public static func medium() {
        impact(.medium)
    }
    
    public static func heavy() {
        impact(.heavy)
    }
    
    public static func soft() {
        impact(.soft)
    }
    
    public static func rigid() {
        impact(.rigid)
    }
    
    // MARK: - Notification Feedback
    
    /// Provide notification haptic feedback
    public static func notification(_ type: NotificationType) {
        #if os(iOS)
        Task { @MainActor in
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            
            let feedbackType: UINotificationFeedbackGenerator.FeedbackType
            switch type {
            case .success:
                feedbackType = .success
            case .warning:
                feedbackType = .warning
            case .error:
                feedbackType = .error
            }
            
            generator.notificationOccurred(feedbackType)
            hapticsLogger.debug("Notification haptic triggered: \(String(describing: type))")
        }
        #elseif os(macOS)
        // macOS fallback: system sounds
        switch type {
        case .success:
            NSSound(named: "Glass")?.play()
        case .warning:
            NSSound(named: "Sosumi")?.play()
        case .error:
            NSSound(named: "Basso")?.play()
        }
        
        hapticsLogger.debug("macOS sound feedback for notification: \(String(describing: type))")
        #endif
    }
    
    /// Convenience methods for common notification types
    public static func success() {
        notification(.success)
    }
    
    public static func warning() {
        notification(.warning)
    }
    
    public static func error() {
        notification(.error)
    }
    
    // MARK: - Selection Feedback
    
    /// Provide selection haptic feedback
    public static func selection() {
        #if os(iOS)
        Task { @MainActor in
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            generator.selectionChanged()
            hapticsLogger.debug("Selection haptic triggered")
        }
        #elseif os(macOS)
        // Subtle system sound for selection
        NSSound.beep() // Use system beep instead
        hapticsLogger.debug("macOS selection sound feedback triggered")
        #endif
    }
    
    // MARK: - Capability Checking
    
    /// Whether haptic feedback is supported on this device
    public static var isSupported: Bool {
        #if os(iOS)
        // Check if device supports haptics (iPhone 7+ and newer)
        return UIDevice.current.userInterfaceIdiom == .phone
        #elseif os(macOS)
        // macOS supports sound feedback as fallback
        return true
        #endif
    }
    
    /// Whether true haptic feedback (not just sound) is available
    public static var isTrueHapticsSupported: Bool {
        #if os(iOS)
        return isSupported
        #elseif os(macOS)
        return false // macOS only has sound feedback
        #endif
    }
    
    // MARK: - Advanced Feedback
    
    /// Custom impact with intensity value (0.0 to 1.0)
    public static func customImpact(intensity: CGFloat) {
        let clampedIntensity = max(0.0, min(1.0, intensity))
        
        #if os(iOS)
        Task { @MainActor in
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred(intensity: clampedIntensity)
            hapticsLogger.debug("Custom impact haptic triggered: intensity \(clampedIntensity)")
        }
        #elseif os(macOS)
        // Scale sound volume based on intensity
        let soundName: NSSound.Name = clampedIntensity > 0.7 ? "Purr" : (clampedIntensity > 0.3 ? "Ping" : "Funk")
        if let sound = NSSound(named: soundName) {
            sound.volume = Float(clampedIntensity)
            sound.play()
        }
        hapticsLogger.debug("macOS scaled sound feedback: intensity \(clampedIntensity)")
        #endif
    }
    
    // MARK: - Batch Operations
    
    /// Prepare haptic generators for reduced latency
    public static func prepareHaptics() {
        #if os(iOS)
        Task { @MainActor in
            // Pre-warm haptic generators
            UIImpactFeedbackGenerator(style: .light).prepare()
            UIImpactFeedbackGenerator(style: .medium).prepare()
            UIImpactFeedbackGenerator(style: .heavy).prepare()
            UINotificationFeedbackGenerator().prepare()
            UISelectionFeedbackGenerator().prepare()
            
            hapticsLogger.debug("Haptic generators prepared for reduced latency")
        }
        #elseif os(macOS)
        // No preparation needed for macOS sound feedback
        hapticsLogger.debug("macOS sound system ready (no preparation needed)")
        #endif
    }
    
    /// Disable haptic feedback globally (user preference)
    public static var isEnabled: Bool = true {
        didSet {
            hapticsLogger.info("Haptic feedback \(isEnabled ? "enabled" : "disabled")")
        }
    }
    
    // MARK: - Internal Helpers
    
    private static func performHaptic(_ block: @escaping () -> Void) {
        guard isEnabled else {
            hapticsLogger.debug("Haptic feedback skipped (disabled)")
            return
        }
        
        #if os(iOS)
        // Check system haptic settings
        if UIDevice.current.userInterfaceIdiom == .phone {
            block()
        } else {
            hapticsLogger.debug("Haptic feedback skipped (iPad/unsupported device)")
        }
        #elseif os(macOS)
        block()
        #endif
    }
}

// MARK: - UIImpactFeedbackGenerator.FeedbackStyle Extensions

#if os(iOS)
extension UIImpactFeedbackGenerator.FeedbackStyle {
    /// Create from PlatformHaptics intensity
    static func from(_ intensity: PlatformHaptics.ImpactIntensity) -> UIImpactFeedbackGenerator.FeedbackStyle {
        switch intensity {
        case .light, .soft:
            return .light
        case .medium:
            return .medium
        case .heavy, .rigid:
            return .heavy
        }
    }
}
#endif