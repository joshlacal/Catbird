//
//  ScrollPerformanceTelemetryActor.swift
//  Catbird
//
//  Swift 6 Actor-based performance telemetry for scroll preservation
//  Thread-safe metrics collection with iOS 18 optimizations
//

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import os

/// Swift 6 Actor for thread-safe scroll performance telemetry
@available(iOS 18.0, *)
actor ScrollPerformanceTelemetryActor {
    
    // MARK: - Types
    
    /// Comprehensive scroll restoration metrics
    struct ScrollRestorationMetrics {
        let timestamp: TimeInterval
        let success: Bool
        let pixelError: Double
        let frameRate: Double
        let duration: TimeInterval
        let updateLinkFrames: Int
        let thermalState: ProcessInfo.ThermalState
        let batteryLevel: Float
        let memoryUsage: UInt64
        let isProMotionDisplay: Bool
        let scrollStrategy: String
    }
    
    /// Frame rate performance tracking
    struct FrameRateMetrics {
        let timestamp: TimeInterval
        let requestedMinimum: Float
        let requestedMaximum: Float
        let requestedPreferred: Float
        let actualFrameRate: Double
        let droppedFrames: Int
        let context: String
    }
    
    /// Memory usage tracking
    struct MemoryMetrics {
        let timestamp: TimeInterval
        let totalMemory: UInt64
        let availableMemory: UInt64
        let appMemoryUsage: UInt64
        let context: String
    }
    
    /// UIUpdateLink efficiency metrics
    struct UIUpdateLinkMetrics {
        let timestamp: TimeInterval
        let totalFrames: Int
        let immediateFrames: Int
        let lowLatencyFrames: Int
        let totalDuration: TimeInterval
        let averageFrameTime: TimeInterval
        let efficiency: Double // immediate frames / total frames
    }
    
    /// UIUpdateLink session tracking
    private struct UIUpdateLinkSession {
        let startTime: TimeInterval
        var totalFrames: Int
        var immediateFrames: Int
        var lowLatencyFrames: Int
    }
    
    /// Memory monitoring utility
    private struct MemoryMonitor {
        func getCurrentMemoryUsage() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            
            let kerr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            
            return kerr == KERN_SUCCESS ? info.resident_size : 0
        }
        
        func getAvailableMemory() -> UInt64 {
            return getTotalMemory() - getCurrentMemoryUsage()
        }
        
        func getTotalMemory() -> UInt64 {
            return UInt64(ProcessInfo.processInfo.physicalMemory)
        }
    }
    
    /// Aggregated performance summary
    struct PerformanceSummary {
        let scrollRestorations: [ScrollRestorationMetrics]
        let frameRateMetrics: [FrameRateMetrics]
        let memoryMetrics: [MemoryMetrics]
        let updateLinkMetrics: [UIUpdateLinkMetrics]
        let generatedAt: Date
        
        var successRate: Double {
            guard !scrollRestorations.isEmpty else { return 0 }
            let successful = scrollRestorations.filter { $0.success }.count
            return Double(successful) / Double(scrollRestorations.count)
        }
        
        var averagePixelError: Double {
            guard !scrollRestorations.isEmpty else { return 0 }
            let totalError = scrollRestorations.reduce(0) { $0 + $1.pixelError }
            return totalError / Double(scrollRestorations.count)
        }
        
        var averageRestorationTime: TimeInterval {
            guard !scrollRestorations.isEmpty else { return 0 }
            let totalTime = scrollRestorations.reduce(0) { $0 + $1.duration }
            return totalTime / Double(scrollRestorations.count)
        }
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird.telemetry", category: "ScrollPerformance")
    
    /// Metrics storage with size limits for memory management
    private var scrollRestorations: [ScrollRestorationMetrics] = []
    private var frameRateMetrics: [FrameRateMetrics] = []
    private var memoryMetrics: [MemoryMetrics] = []
    private var updateLinkMetrics: [UIUpdateLinkMetrics] = []
    
    /// Configuration
    private let maxMetricsPerType: Int = 1000
    private let metricsRetentionPeriod: TimeInterval = 3600 // 1 hour
    
    /// Memory monitoring
    private let memoryMonitor = MemoryMonitor()
    
    /// Current UIUpdateLink session tracking
    private var currentUpdateLinkSession: UIUpdateLinkSession?
    
    // MARK: - Initialization
    
    init() {
        logger.info("📊 ScrollPerformanceTelemetryActor initialized")
        Task {
            await startPeriodicCleanup()
        }
    }
    
    // MARK: - Scroll Restoration Tracking
    
    /// Record a scroll restoration attempt
    func recordScrollRestoration(
        success: Bool,
        error: Double,
        frameRate: Double,
        duration: TimeInterval,
        updateLinkFrames: Int = 0,
        scrollStrategy: String = "default"
    ) async {
        let memoryUsage = memoryMonitor.getCurrentMemoryUsage()
        let isProMotionDisplay = await MainActor.run { PlatformScreenInfo.isProMotionDisplay }
        let batteryLevel = await MainActor.run { PlatformDeviceInfo.batteryLevel }
        
        let metrics = ScrollRestorationMetrics(
            timestamp: CACurrentMediaTime(),
            success: success,
            pixelError: error,
            frameRate: frameRate,
            duration: duration,
            updateLinkFrames: updateLinkFrames,
            thermalState: ProcessInfo.processInfo.thermalState,
            batteryLevel: batteryLevel >= 0 ? batteryLevel : -1.0, // Handle unknown battery level
            memoryUsage: memoryUsage,
            isProMotionDisplay: isProMotionDisplay,
            scrollStrategy: scrollStrategy
        )
        
        scrollRestorations.append(metrics)
        enforceStorageLimit()
        
        logger.debug("📈 Recorded scroll restoration: success=\(success), error=\(error)px, duration=\(duration * 1000)ms")
        
        // Log performance warnings
        if error > 1.0 {
            logger.warning("⚠️ High pixel error in scroll restoration: \(error)px")
        }
        if duration > 0.1 {
            logger.warning("⚠️ Slow scroll restoration: \(duration * 1000)ms")
        }
    }
    
    // MARK: - Frame Rate Tracking
    
    /// Record frame rate performance
    func recordFrameRate(
        requested: CAFrameRateRange,
        actual: Double,
        droppedFrames: Int,
        context: String
    ) {
        let metrics = FrameRateMetrics(
            timestamp: CACurrentMediaTime(),
            requestedMinimum: requested.minimum,
            requestedMaximum: requested.maximum,
            requestedPreferred: requested.preferred ?? 60.0,
            actualFrameRate: actual,
            droppedFrames: droppedFrames,
            context: context
        )
        
        frameRateMetrics.append(metrics)
        enforceFrameRateLimit()
        
        logger.debug("🎭 Recorded frame rate: requested=\(requested.preferred ?? 60.0), actual=\(actual), dropped=\(droppedFrames)")
    }
    
    // MARK: - Memory Tracking
    
    /// Record memory usage at specific context
    func recordMemoryUsage(context: String) {
        let currentMemory = memoryMonitor.getCurrentMemoryUsage()
        let availableMemory = memoryMonitor.getAvailableMemory()
        let totalMemory = memoryMonitor.getTotalMemory()
        
        let metrics = MemoryMetrics(
            timestamp: CACurrentMediaTime(),
            totalMemory: totalMemory,
            availableMemory: availableMemory,
            appMemoryUsage: currentMemory,
            context: context
        )
        
        memoryMetrics.append(metrics)
        enforceMemoryLimit()
        
        logger.debug("💾 Recorded memory usage: \(currentMemory / 1024 / 1024)MB (\(context))")
        
        // Warn about high memory usage
        let memoryPercentage = Double(currentMemory) / Double(totalMemory)
        if memoryPercentage > 0.8 {
            logger.warning("⚠️ High memory usage: \(Int(memoryPercentage * 100))%")
        }
    }
    
    // MARK: - UIUpdateLink Session Tracking
    
    /// Start tracking a UIUpdateLink session
    func startUIUpdateLinkSession() {
        currentUpdateLinkSession = UIUpdateLinkSession(
            startTime: CACurrentMediaTime(),
            totalFrames: 0,
            immediateFrames: 0,
            lowLatencyFrames: 0
        )
        
        logger.debug("🔗 Started UIUpdateLink session tracking")
    }
    
    /// Record a UIUpdateLink frame
    func recordUIUpdateLinkFrame(
        isImmediate: Bool,
        isLowLatency: Bool
    ) {
        guard var session = currentUpdateLinkSession else {
            logger.warning("⚠️ Recording UIUpdateLink frame without active session")
            return
        }
        
        session.totalFrames += 1
        if isImmediate {
            session.immediateFrames += 1
        }
        if isLowLatency {
            session.lowLatencyFrames += 1
        }
        
        currentUpdateLinkSession = session
    }
    
    /// End UIUpdateLink session tracking
    func endUIUpdateLinkSession() {
        guard let session = currentUpdateLinkSession else {
            logger.warning("⚠️ Ending UIUpdateLink session without active session")
            return
        }
        
        let duration = CACurrentMediaTime() - session.startTime
        let efficiency = session.totalFrames > 0 ? Double(session.immediateFrames) / Double(session.totalFrames) : 0
        let averageFrameTime = session.totalFrames > 0 ? duration / Double(session.totalFrames) : 0
        
        let metrics = UIUpdateLinkMetrics(
            timestamp: session.startTime,
            totalFrames: session.totalFrames,
            immediateFrames: session.immediateFrames,
            lowLatencyFrames: session.lowLatencyFrames,
            totalDuration: duration,
            averageFrameTime: averageFrameTime,
            efficiency: efficiency
        )
        
        updateLinkMetrics.append(metrics)
        enforceUpdateLinkLimit()
        currentUpdateLinkSession = nil
        
        logger.debug("🔗 Ended UIUpdateLink session: efficiency=\(Int(efficiency * 100))%, frames=\(session.totalFrames)")
    }
    
    // MARK: - Analytics & Reporting
    
    /// Generate comprehensive performance summary
    func generatePerformanceSummary() -> PerformanceSummary {
        // Clean old data before generating summary
        cleanOldMetrics()
        
        let summary = PerformanceSummary(
            scrollRestorations: Array(scrollRestorations),
            frameRateMetrics: Array(frameRateMetrics),
            memoryMetrics: Array(memoryMetrics),
            updateLinkMetrics: Array(updateLinkMetrics),
            generatedAt: Date()
        )
        
        logger.info("📋 Generated performance summary: \(self.scrollRestorations.count) restorations, \(Int(summary.successRate * 100))% success rate")
        
        return summary
    }
    
    /// Get recent performance metrics for real-time monitoring
    func getRecentMetrics(since: TimeInterval) -> (restorations: [ScrollRestorationMetrics], frameRates: [FrameRateMetrics]) {
        let currentTime = CACurrentMediaTime()
        let cutoffTime = currentTime - since
        
        let recentRestorations = scrollRestorations.filter { $0.timestamp >= cutoffTime }
        let recentFrameRates = frameRateMetrics.filter { $0.timestamp >= cutoffTime }
        
        return (recentRestorations, recentFrameRates)
    }
    
    /// Export metrics for A/B testing analysis
    func exportMetricsForABTesting() -> [String: Any] {
        let summary = generatePerformanceSummary()
        
        return [
            "success_rate": summary.successRate,
            "average_pixel_error": summary.averagePixelError,
            "average_restoration_time_ms": summary.averageRestorationTime * 1000,
            "total_restorations": summary.scrollRestorations.count,
            "pro_motion_percentage": summary.scrollRestorations.filter { $0.isProMotionDisplay }.count,
            "thermal_throttling_events": summary.scrollRestorations.filter { $0.thermalState != .nominal }.count,
            "low_battery_events": summary.scrollRestorations.filter { $0.batteryLevel < 0.2 }.count,
            "update_link_efficiency": updateLinkMetrics.last?.efficiency ?? 0,
            "export_timestamp": Date().timeIntervalSince1970
        ]
    }
    
    // MARK: - Private Implementation
    
    private func enforceStorageLimit() {
        if scrollRestorations.count > maxMetricsPerType {
            // Remove oldest 20% to prevent frequent trimming
            let removeCount = maxMetricsPerType / 5
            scrollRestorations.removeFirst(removeCount)
        }
    }
    
    private func enforceFrameRateLimit() {
        if frameRateMetrics.count > maxMetricsPerType {
            let removeCount = maxMetricsPerType / 5
            frameRateMetrics.removeFirst(removeCount)
        }
    }
    
    private func enforceMemoryLimit() {
        if memoryMetrics.count > maxMetricsPerType {
            let removeCount = maxMetricsPerType / 5
            memoryMetrics.removeFirst(removeCount)
        }
    }
    
    private func enforceUpdateLinkLimit() {
        if updateLinkMetrics.count > maxMetricsPerType {
            let removeCount = maxMetricsPerType / 5
            updateLinkMetrics.removeFirst(removeCount)
        }
    }
    
    private func cleanOldMetrics() {
        let cutoffTime = CACurrentMediaTime() - metricsRetentionPeriod
        
        scrollRestorations.removeAll { $0.timestamp < cutoffTime }
        frameRateMetrics.removeAll { $0.timestamp < cutoffTime }
        memoryMetrics.removeAll { $0.timestamp < cutoffTime }
        updateLinkMetrics.removeAll { $0.timestamp < cutoffTime }
    }
    
    private func startPeriodicCleanup() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
            cleanOldMetrics()
        }
    }
}


// MARK: - Extensions

@available(iOS 18.0, *)
extension ScrollPerformanceTelemetryActor.PerformanceSummary {
    /// Generate A/B testing compatible metrics
    var abTestingMetrics: [String: Double] {
        return [
            "success_rate": successRate,
            "average_pixel_error": averagePixelError,
            "average_restoration_time": averageRestorationTime,
            "frame_drops_per_second": calculateAverageFrameDrops(),
            "memory_efficiency": calculateMemoryEfficiency(),
            "update_link_efficiency": calculateUpdateLinkEfficiency()
        ]
    }
    
    private func calculateAverageFrameDrops() -> Double {
        guard !frameRateMetrics.isEmpty else { return 0 }
        let totalDrops = frameRateMetrics.reduce(0) { $0 + $1.droppedFrames }
        return Double(totalDrops) / Double(frameRateMetrics.count)
    }
    
    private func calculateMemoryEfficiency() -> Double {
        guard !memoryMetrics.isEmpty else { return 1.0 }
        // Calculate based on memory usage stability
        let memoryUsages = memoryMetrics.map { Double($0.appMemoryUsage) }
        let averageUsage = memoryUsages.reduce(0, +) / Double(memoryUsages.count)
        let maxUsage = memoryUsages.max() ?? averageUsage
        return averageUsage / maxUsage // Higher is better (more stable)
    }
    
    private func calculateUpdateLinkEfficiency() -> Double {
        guard !updateLinkMetrics.isEmpty else { return 0 }
        let totalEfficiency = updateLinkMetrics.reduce(0) { $0 + $1.efficiency }
        return totalEfficiency / Double(updateLinkMetrics.count)
    }
}