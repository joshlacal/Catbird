//
//  UIUpdateLinkMetrics.swift
//  Catbird
//
//  Created by Claude on iOS 18 UIUpdateLink optimization metrics
//
//  Performance monitoring and metrics collection for UIUpdateLink optimizations
//

import Foundation
import UIKit
import os

@available(iOS 18.0, *)
final class UIUpdateLinkMetrics {
    
    // MARK: - Singleton
    
    static let shared = UIUpdateLinkMetrics()
    private init() {}
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird", category: "UIUpdateLinkMetrics")
    private let metricsQueue = DispatchQueue(label: "com.catbird.metrics", qos: .utility)
    
    // Performance tracking
    private var frameDropCounts: [String: Int] = [:]
    private var updateLatencies: [String: [CFTimeInterval]] = [:]
    private var cpuUsageHistory: [Double] = []
    private var memoryUsageHistory: [UInt64] = []
    
    // Session tracking
    private var sessionStartTime: CFTimeInterval = 0
    private var totalFrames: [String: Int] = [:]
    private var successfulFrames: [String: Int] = [:]
    
    // MARK: - Public Interface
    
    /// Starts a metrics collection session
    func startSession() {
        metricsQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.sessionStartTime = CACurrentMediaTime()
            self.frameDropCounts.removeAll()
            self.updateLatencies.removeAll()
            self.cpuUsageHistory.removeAll()
            self.memoryUsageHistory.removeAll()
            self.totalFrames.removeAll()
            self.successfulFrames.removeAll()
            
            self.logger.info("UIUpdateLink metrics session started")
        }
    }
    
    /// Records a frame update for the specified link type
    func recordFrameUpdate(for linkType: UIUpdateLinkType, latency: CFTimeInterval, dropped: Bool = false) {
        metricsQueue.async { [weak self] in
            guard let self = self else { return }
            
            let typeKey = linkType.rawValue
            
            // Track total frames
            self.totalFrames[typeKey, default: 0] += 1
            
            if !dropped {
                // Track successful frames and latencies
                self.successfulFrames[typeKey, default: 0] += 1
                self.updateLatencies[typeKey, default: []].append(latency)
                
                // Keep latency history reasonable
                if self.updateLatencies[typeKey]!.count > 1000 {
                    self.updateLatencies[typeKey]!.removeFirst(500)
                }
            } else {
                // Track frame drops
                self.frameDropCounts[typeKey, default: 0] += 1
                self.logger.debug("Frame drop recorded for \(typeKey)")
            }
        }
    }
    
    /// Records system resource usage
    func recordSystemMetrics() {
        metricsQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Record CPU usage
            let cpuUsage = self.getCurrentCPUUsage()
            self.cpuUsageHistory.append(cpuUsage)
            
            // Record memory usage
            let memoryUsage = self.getCurrentMemoryUsage()
            self.memoryUsageHistory.append(memoryUsage)
            
            // Keep history manageable
            if self.cpuUsageHistory.count > 1000 {
                self.cpuUsageHistory.removeFirst(500)
            }
            if self.memoryUsageHistory.count > 1000 {
                self.memoryUsageHistory.removeFirst(500)
            }
        }
    }
    
    /// Generates a comprehensive metrics report
    func generateReport() -> UIUpdateLinkMetricsReport {
        return metricsQueue.sync {
            let sessionDuration = CACurrentMediaTime() - sessionStartTime
            
            var linkMetrics: [String: UIUpdateLinkTypeMetrics] = [:]
            
            for linkType in UIUpdateLinkType.allCases {
                let typeKey = linkType.rawValue
                let total = totalFrames[typeKey] ?? 0
                let successful = successfulFrames[typeKey] ?? 0
                let dropped = frameDropCounts[typeKey] ?? 0
                let latencies = updateLatencies[typeKey] ?? []
                
                let averageLatency = latencies.isEmpty ? 0 : latencies.reduce(0, +) / Double(latencies.count)
                let maxLatency = latencies.max() ?? 0
                let minLatency = latencies.min() ?? 0
                
                linkMetrics[typeKey] = UIUpdateLinkTypeMetrics(
                    totalFrames: total,
                    successfulFrames: successful,
                    droppedFrames: dropped,
                    averageLatency: averageLatency,
                    maxLatency: maxLatency,
                    minLatency: minLatency,
                    successRate: total > 0 ? Double(successful) / Double(total) : 0
                )
            }
            
            let averageCPU = cpuUsageHistory.isEmpty ? 0 : cpuUsageHistory.reduce(0, +) / Double(cpuUsageHistory.count)
            let maxCPU = cpuUsageHistory.max() ?? 0
            
            let averageMemory = memoryUsageHistory.isEmpty ? 0 : memoryUsageHistory.reduce(0, +) / UInt64(memoryUsageHistory.count)
            let maxMemory = memoryUsageHistory.max() ?? 0
            
            return UIUpdateLinkMetricsReport(
                sessionDuration: sessionDuration,
                linkMetrics: linkMetrics,
                systemMetrics: UIUpdateLinkSystemMetrics(
                    averageCPUUsage: averageCPU,
                    maxCPUUsage: maxCPU,
                    averageMemoryUsage: averageMemory,
                    maxMemoryUsage: maxMemory
                )
            )
        }
    }
    
    /// Logs current metrics for debugging
    func logCurrentMetrics() {
        let report = generateReport()
        logger.info("UIUpdateLink Metrics Report:")
        logger.info("Session Duration: \(report.sessionDuration)s")
        
        for (linkType, metrics) in report.linkMetrics {
            logger.info("\(linkType): \(metrics.successfulFrames)/\(metrics.totalFrames) frames (\(String(format: "%.1f", metrics.successRate * 100))% success), avg latency: \(String(format: "%.3f", metrics.averageLatency))ms")
        }
        
        logger.info("System: CPU \(String(format: "%.1f", report.systemMetrics.averageCPUUsage))% avg, Memory \(report.systemMetrics.averageMemoryUsage / 1024 / 1024)MB avg")
    }
    
    // MARK: - Private Methods
    
    private func getCurrentCPUUsage() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            // Convert to percentage (rough approximation)
            return Double(info.resident_size) / Double(1024 * 1024) * 0.1 // Simplified calculation
        }
        
        return 0.0
    }
    
    private func getCurrentMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            return UInt64(info.resident_size)
        }
        
        return 0
    }
}

// MARK: - Supporting Types

@available(iOS 18.0, *)
enum UIUpdateLinkType: String, CaseIterable {
    case pullRefresh = "pullRefresh"
    case stateObservation = "stateObservation"
    case scrollTracking = "scrollTracking"
    case contentUpdate = "contentUpdate"
}

struct UIUpdateLinkTypeMetrics {
    let totalFrames: Int
    let successfulFrames: Int
    let droppedFrames: Int
    let averageLatency: CFTimeInterval
    let maxLatency: CFTimeInterval
    let minLatency: CFTimeInterval
    let successRate: Double
}

struct UIUpdateLinkSystemMetrics {
    let averageCPUUsage: Double
    let maxCPUUsage: Double
    let averageMemoryUsage: UInt64
    let maxMemoryUsage: UInt64
}

struct UIUpdateLinkMetricsReport {
    let sessionDuration: CFTimeInterval
    let linkMetrics: [String: UIUpdateLinkTypeMetrics]
    let systemMetrics: UIUpdateLinkSystemMetrics
    
    /// Compares this report with a baseline to identify performance improvements
    func compareWith(baseline: UIUpdateLinkMetricsReport) -> UIUpdateLinkPerformanceComparison {
        var improvements: [String] = []
        var regressions: [String] = []
        
        for (linkType, metrics) in linkMetrics {
            guard let baselineMetrics = baseline.linkMetrics[linkType] else { continue }
            
            // Compare success rates
            let successRateDelta = metrics.successRate - baselineMetrics.successRate
            if successRateDelta > 0.05 {
                improvements.append("\(linkType) success rate improved by \(String(format: "%.1f", successRateDelta * 100))%")
            } else if successRateDelta < -0.05 {
                regressions.append("\(linkType) success rate decreased by \(String(format: "%.1f", abs(successRateDelta) * 100))%")
            }
            
            // Compare latencies
            let latencyDelta = metrics.averageLatency - baselineMetrics.averageLatency
            if latencyDelta < -0.001 {
                improvements.append("\(linkType) latency improved by \(String(format: "%.3f", abs(latencyDelta)))ms")
            } else if latencyDelta > 0.001 {
                regressions.append("\(linkType) latency increased by \(String(format: "%.3f", latencyDelta))ms")
            }
        }
        
        // Compare system metrics
        let cpuDelta = systemMetrics.averageCPUUsage - baseline.systemMetrics.averageCPUUsage
        if cpuDelta < -1.0 {
            improvements.append("CPU usage improved by \(String(format: "%.1f", abs(cpuDelta)))%")
        } else if cpuDelta > 1.0 {
            regressions.append("CPU usage increased by \(String(format: "%.1f", cpuDelta))%")
        }
        
        let memoryDelta = Int64(systemMetrics.averageMemoryUsage) - Int64(baseline.systemMetrics.averageMemoryUsage)
        if memoryDelta < -1024 * 1024 {
            improvements.append("Memory usage improved by \(abs(memoryDelta) / 1024 / 1024)MB")
        } else if memoryDelta > 1024 * 1024 {
            regressions.append("Memory usage increased by \(memoryDelta / 1024 / 1024)MB")
        }
        
        return UIUpdateLinkPerformanceComparison(
            improvements: improvements,
            regressions: regressions
        )
    }
}

struct UIUpdateLinkPerformanceComparison {
    let improvements: [String]
    let regressions: [String]
    
    var hasImprovements: Bool { !improvements.isEmpty }
    var hasRegressions: Bool { !regressions.isEmpty }
    var overallImprovement: Bool { improvements.count > regressions.count }
}

// MARK: - Integration with FeedCollectionViewController

@available(iOS 18.0, *)
extension FeedCollectionViewControllerIntegrated {
    
    /// Starts metrics collection for this controller
    func startUIUpdateLinkMetricsCollection() {
        UIUpdateLinkMetrics.shared.startSession()
        
        // Set up periodic system metrics collection
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            UIUpdateLinkMetrics.shared.recordSystemMetrics()
        }
    }
    
    /// Records metrics for a UIUpdateLink frame update
    func recordUIUpdateLinkMetrics(for linkType: UIUpdateLinkType, startTime: CFTimeInterval, dropped: Bool = false) {
        let latency = CACurrentMediaTime() - startTime
        UIUpdateLinkMetrics.shared.recordFrameUpdate(for: linkType, latency: latency, dropped: dropped)
    }
    
    /// Generates and logs current metrics
    func logUIUpdateLinkMetrics() {
        UIUpdateLinkMetrics.shared.logCurrentMetrics()
    }
}
