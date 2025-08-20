//
//  AdaptiveFrameRateManager.swift
//  Catbird
//
//  iOS 18+ Adaptive Frame Rate Management for optimal scroll performance
//  Integrates with ProMotion displays and battery-aware performance scaling
//

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import os

// Need to import PlatformSystem for cross-platform notifications
// The notifications should come from the PlatformApplication struct there

@available(iOS 18.0, *)
@MainActor
final class AdaptiveFrameRateManager {
    
    // MARK: - Types
    
    /// Different performance contexts requiring different frame rates
    enum PerformanceContext {
        case scrollRestoration
        case liveScrolling
        case staticContent
        case backgroundRefresh
        case memoryPressure
        
        var baseFrameRate: CAFrameRateRange {
            switch self {
            case .scrollRestoration:
                return CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            case .liveScrolling:
                return CAFrameRateRange(minimum: 60, maximum: 120, preferred: 90)
            case .staticContent:
                return CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            case .backgroundRefresh:
                return CAFrameRateRange(minimum: 15, maximum: 30, preferred: 24)
            case .memoryPressure:
                return CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            }
        }
    }
    
    /// Battery level considerations for frame rate optimization
    enum BatteryOptimization {
        case high      // > 50%
        case medium    // 20-50%
        case low       // < 20%
        case charging  // Plugged in
        
        var frameRateMultiplier: Float {
            switch self {
            case .high, .charging:
                return 1.0
            case .medium:
                return 0.8
            case .low:
                return 0.6
            }
        }
    }
    
    /// Scroll velocity-based frame rate scaling
    struct VelocityFrameRate {
        let velocity: CGFloat
        let recommendedFrameRate: CAFrameRateRange
        
        static func frameRate(for velocity: CGFloat, isProMotion: Bool) -> CAFrameRateRange {
            let absVelocity = abs(velocity)
            
            if !isProMotion {
                // Standard 60Hz displays
                return CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            }
            
            // ProMotion adaptive frame rates based on scroll velocity
            switch absVelocity {
            case 0...100:
                // Slow scrolling - optimize for power
                return CAFrameRateRange(minimum: 60, maximum: 80, preferred: 60)
            case 100...500:
                // Medium scrolling - balanced performance
                return CAFrameRateRange(minimum: 80, maximum: 90, preferred: 80)
            case 500...1000:
                // Fast scrolling - prioritize smoothness
                return CAFrameRateRange(minimum: 90, maximum: 120, preferred: 90)
            default:
                // Very fast scrolling - maximum smoothness
                return CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
            }
        }
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird", category: "AdaptiveFrameRate")
    
    /// Current system performance level
    private var currentPerformanceLevel: Float = 1.0
    
    /// Battery monitoring
    #if os(iOS)
    private let batteryMonitor = BatteryPerformanceMonitor()
    #endif
    
    /// Thermal state monitoring
    private var thermalState: ProcessInfo.ThermalState = .nominal
    
    /// Memory pressure monitoring
    private var isUnderMemoryPressure: Bool = false
    
    // MARK: - Initialization
    
    init() {
        setupPerformanceMonitoring()
        logger.info("🎭 AdaptiveFrameRateManager initialized")
    }
    
    // MARK: - Public Interface
    
    /// Get optimal frame rate for given context and conditions
    func getOptimalFrameRate(
        for context: PerformanceContext,
        isProMotionDisplay: Bool,
        scrollVelocity: CGFloat = 0,
        batteryLevel: Float = 1.0
    ) -> CAFrameRateRange {
        
        // Start with base frame rate for context
        var frameRate = context.baseFrameRate
        
        // Apply ProMotion scaling if available
        if !isProMotionDisplay {
            frameRate = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        }
        
        // Apply velocity-based scaling for scroll contexts
        if context == .liveScrolling && scrollVelocity > 0 {
            let velocityFrameRate = VelocityFrameRate.frameRate(for: scrollVelocity, isProMotion: isProMotionDisplay)
            frameRate = combineFrameRates(primary: frameRate, secondary: velocityFrameRate)
        }
        
        // Apply battery optimization
        let batteryOptimization = getBatteryOptimization(batteryLevel: batteryLevel)
        frameRate = applyBatteryOptimization(frameRate, optimization: batteryOptimization)
        
        // Apply thermal throttling
        frameRate = applyThermalThrottling(frameRate, thermalState: thermalState)
        
        // Apply memory pressure scaling
        if isUnderMemoryPressure {
            frameRate = applyMemoryPressureScaling(frameRate)
        }
        
        logger.debug("📊 Optimal frame rate for \(String(describing: context)): \(String(describing: frameRate.minimum))-\(String(describing: frameRate.maximum)) (preferred: \(String(describing: frameRate.preferred))")
        
        return frameRate
    }
    
    /// Get frame rate specifically optimized for scroll restoration
    func getScrollRestorationFrameRate(
        isProMotionDisplay: Bool,
        batteryLevel: Float
    ) -> CAFrameRateRange {
        return getOptimalFrameRate(
            for: .scrollRestoration,
            isProMotionDisplay: isProMotionDisplay,
            batteryLevel: batteryLevel
        )
    }
    
    /// Update performance level based on system conditions
    func updatePerformanceLevel(_ level: Float) {
        currentPerformanceLevel = max(0.1, min(1.0, level))
        logger.debug("🎚️ Performance level updated to: \(self.currentPerformanceLevel)")
    }
    
    // MARK: - Private Implementation
    
    private func setupPerformanceMonitoring() {
        // Monitor thermal state
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.thermalState = ProcessInfo.processInfo.thermalState
            self?.logger.debug("🌡️ Thermal state changed: \(String(describing: self?.thermalState))")
        }
        
        // Monitor memory pressure (simplified - in production use os_proc_available_memory)
        NotificationCenter.default.addObserver(
            forName: PlatformApplication.memoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isUnderMemoryPressure = true
            self?.logger.warning("⚠️ Memory pressure detected")
            
            // Reset memory pressure flag after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                self?.isUnderMemoryPressure = false
            }
        }
    }
    
    private func getBatteryOptimization(batteryLevel: Float) -> BatteryOptimization {
        #if os(iOS)
        let batteryState = PlatformDeviceInfo.batteryState
        
        if batteryState == .charging || batteryState == .full {
            return .charging
        }
        #elseif os(macOS)
        // macOS doesn't have battery state monitoring like iOS
        // Assume we're always charging/plugged in for frame rate purposes
        return .charging
        #endif
        
        if batteryLevel > 0.5 {
            return .high
        } else if batteryLevel > 0.2 {
            return .medium
        } else {
            return .low
        }
    }
    
    private func applyBatteryOptimization(
        _ frameRate: CAFrameRateRange,
        optimization: BatteryOptimization
    ) -> CAFrameRateRange {
        let multiplier = optimization.frameRateMultiplier
        
        return CAFrameRateRange(
            minimum: frameRate.minimum * multiplier,
            maximum: frameRate.maximum * multiplier,
            preferred: (frameRate.preferred ?? frameRate.maximum) * multiplier
        )
    }
    
    private func applyThermalThrottling(
        _ frameRate: CAFrameRateRange,
        thermalState: ProcessInfo.ThermalState
    ) -> CAFrameRateRange {
        let throttleMultiplier: Float
        
        switch thermalState {
        case .nominal:
            throttleMultiplier = 1.0
        case .fair:
            throttleMultiplier = 0.9
        case .serious:
            throttleMultiplier = 0.7
        case .critical:
            throttleMultiplier = 0.5
        @unknown default:
            throttleMultiplier = 1.0
        }
        
        return CAFrameRateRange(
            minimum: frameRate.minimum * throttleMultiplier,
            maximum: frameRate.maximum * throttleMultiplier,
            preferred: (frameRate.preferred ?? frameRate.maximum) * throttleMultiplier
        )
    }
    
    private func applyMemoryPressureScaling(
        _ frameRate: CAFrameRateRange
    ) -> CAFrameRateRange {
        // Reduce frame rate by 30% under memory pressure
        let multiplier: Float = 0.7
        
        return CAFrameRateRange(
            minimum: max(15, frameRate.minimum * multiplier),
            maximum: max(30, frameRate.maximum * multiplier),
            preferred: max(30, (frameRate.preferred ?? frameRate.maximum) * multiplier)
        )
    }
    
    private func combineFrameRates(
        primary: CAFrameRateRange,
        secondary: CAFrameRateRange
    ) -> CAFrameRateRange {
        // Take the more conservative range for stability
        return CAFrameRateRange(
            minimum: min(primary.minimum, secondary.minimum),
            maximum: min(primary.maximum, secondary.maximum),
            preferred: min(primary.preferred ?? primary.maximum, secondary.preferred ?? secondary.maximum)
        )
    }
}

// MARK: - Battery Performance Monitor

#if os(iOS)
@available(iOS 18.0, *)
private class BatteryPerformanceMonitor {
    private let logger = Logger(subsystem: "blue.catbird", category: "BatteryMonitor")
    
    init() {
        Task { @MainActor in
            PlatformDeviceInfo.isBatteryMonitoringEnabled = true
        }
        setupBatteryMonitoring()
    }
    
    private func setupBatteryMonitoring() {
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let level = PlatformDeviceInfo.batteryLevel
            self?.logger.debug("🔋 Battery level changed: \(level * 100)%")
        }
        
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let state = PlatformDeviceInfo.batteryState
            self?.logger.debug("🔌 Battery state changed: \(String(describing: state))")
        }
    }
}
#endif

// MARK: - Extensions

@available(iOS 18.0, *)
extension CAFrameRateRange {
    /// Create a frame rate range with validation
    static func validated(minimum: Float, maximum: Float, preferred: Float) -> CAFrameRateRange {
        let validMin = max(1, minimum)
        let validMax = min(120, maximum)
        let validPreferred = max(validMin, min(validMax, preferred))
        
        return CAFrameRateRange(
            minimum: validMin,
            maximum: validMax,
            preferred: validPreferred
        )
    }
    
    /// Check if this frame rate range supports ProMotion
    var supportsProMotion: Bool {
        return maximum > 60
    }
    
    /// Get battery-efficient variant
    var batteryEfficient: CAFrameRateRange {
        return CAFrameRateRange(
            minimum: max(30, minimum * 0.7),
            maximum: max(60, maximum * 0.7),
            preferred: max(60, (preferred ?? maximum) * 0.7)
        )
    }
}
