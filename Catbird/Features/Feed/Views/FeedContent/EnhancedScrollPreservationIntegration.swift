//
//  EnhancedScrollPreservationIntegration.swift
//  Catbird
//
//  Complete iOS 18 scroll preservation integration layer
//  Combines all enhancements into a unified, production-ready system
//

import UIKit
import SwiftUI
import os
import Combine

@available(iOS 18.0, *)
@MainActor
final class EnhancedScrollPreservationIntegration: ObservableObject {
    
    // MARK: - Types
    
    /// Comprehensive performance monitoring data
    struct SystemPerformanceSnapshot {
        let timestamp: TimeInterval
        let frameRate: Double
        let thermalState: ProcessInfo.ThermalState
        let batteryLevel: Float
        let memoryUsage: UInt64
        let isProMotionActive: Bool
        let scrollVelocity: CGFloat
        
        static func current(scrollVelocity: CGFloat = 0) -> SystemPerformanceSnapshot {
            return SystemPerformanceSnapshot(
                timestamp: CACurrentMediaTime(),
                frameRate: Double(UIScreen.main.maximumFramesPerSecond),
                thermalState: ProcessInfo.processInfo.thermalState,
                batteryLevel: UIDevice.current.batteryLevel,
                memoryUsage: getCurrentMemoryUsage(),
                isProMotionActive: UIScreen.main.maximumFramesPerSecond > 60,
                scrollVelocity: scrollVelocity
            )
        }
        
        private static func getCurrentMemoryUsage() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
            
            let kerr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            
            return kerr == KERN_SUCCESS ? info.resident_size : 0
        }
    }
    
    /// Integration health status
    enum IntegrationStatus {
        case optimal        // All systems working perfectly
        case degraded       // Some features disabled for performance
        case fallback       // Using basic scroll preservation only
        case unavailable    // System resources exhausted
        
        var description: String {
            switch self {
            case .optimal:
                return "Optimal - All iOS 18 features active"
            case .degraded:
                return "Degraded - Some features disabled for performance"
            case .fallback:
                return "Fallback - Basic scroll preservation only"
            case .unavailable:
                return "Unavailable - System resources exhausted"
            }
        }
        
        var color: Color {
            switch self {
            case .optimal:
                return .green
            case .degraded:
                return .yellow
            case .fallback:
                return .orange
            case .unavailable:
                return .red
            }
        }
    }
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird", category: "EnhancedScrollIntegration")
    
    /// Core systems
    private let coordinator = iOS18ScrollPreservationCoordinator()
    private let telemetryActor = ScrollPerformanceTelemetryActor()
    private let frameRateManager = AdaptiveFrameRateManager()
    
    /// A/B Testing integration
    private weak var abTestingFramework: ABTestingFramework?
    
    /// Published state
    @Published private(set) var currentStatus: IntegrationStatus = .optimal
    @Published private(set) var lastPerformanceSnapshot: SystemPerformanceSnapshot = .current()
    @Published private(set) var activeStrategy: String = "iOS 18 Enhanced"
    @Published private(set) var totalRestorations: Int = 0
    @Published private(set) var successRate: Double = 1.0
    
    /// System monitoring
    private var cancellables = Set<AnyCancellable>()
    private let performanceMonitor = Timer.publish(every: 5.0, on: .main, in: .common).autoconnect()
    
    // MARK: - Initialization
    
    init(abTestingFramework: ABTestingFramework? = nil) {
        self.abTestingFramework = abTestingFramework
        
        setupSystemMonitoring()
        startPerformanceTracking()
        
        logger.info("🎆 Enhanced Scroll Preservation Integration initialized")
    }
    
    // MARK: - Public Interface
    
    /// Main entry point for enhanced scroll preservation
    func performScrollPreservation(
        collectionView: UICollectionView,
        dataSource: UICollectionViewDiffableDataSource<Int, String>,
        newData: [String],
        currentData: [String],
        updateType: UnifiedScrollPreservationPipeline.UpdateType,
        getPostId: @escaping (IndexPath) -> String?
    ) async -> iOS18ScrollPreservationCoordinator.RestorationResult {
        
        // Update system status before operation
        await updateSystemStatus()
        
        // Early exit if system is unavailable
        if currentStatus == .unavailable {
            logger.warning("⚠️ System unavailable, skipping scroll preservation")
            return iOS18ScrollPreservationCoordinator.RestorationResult(
                success: false,
                strategy: .standard,
                pixelError: 0,
                duration: 0,
                frameRate: 0,
                updateLinkFrames: 0,
                memoryUsage: 0,
                batteryImpact: 0,
                error: ScrollPreservationError.systemResourcesUnavailable
            )
        }
        
        logger.info("🚀 Starting enhanced scroll preservation - Status: \(self.currentStatus.description)")
        
        // Capture system snapshot before operation
        let preSnapshot = SystemPerformanceSnapshot.current()
        
        // Perform the enhanced scroll preservation
        let result = await coordinator.performEnhancedScrollPreservation(
            collectionView: collectionView,
            dataSource: dataSource,
            newData: newData,
            currentData: currentData,
            updateType: updateType,
            getPostId: getPostId
        )
        
        // Capture post-operation snapshot
        let postSnapshot = SystemPerformanceSnapshot.current()
        
        // Update tracking metrics
        await updateTrackingMetrics(result: result, preSnapshot: preSnapshot, postSnapshot: postSnapshot)
        
        // Update UI state
        await MainActor.run {
            self.totalRestorations += 1
            self.activeStrategy = result.strategy.description
            self.lastPerformanceSnapshot = postSnapshot
            
            // Update success rate (running average)
            let currentSuccesses = Double(totalRestorations - 1) * successRate
            let newSuccesses = currentSuccesses + (result.success ? 1.0 : 0.0)
            self.successRate = newSuccesses / Double(totalRestorations)
        }
        
        logger.info("✅ Enhanced scroll preservation completed - Success: \(result.success), Strategy: \(result.strategy.description)")
        
        return result
    }
    
    /// Get comprehensive performance analytics
    func getPerformanceAnalytics() async -> [String: Any] {
        let telemetryData = await telemetryActor.exportMetricsForABTesting()
        let coordinatorSummary = await coordinator.getPerformanceSummary()
        
        return [
            "integration_status": currentStatus.description,
            "total_restorations": totalRestorations,
            "success_rate": successRate,
            "active_strategy": activeStrategy,
            "last_performance": [
                "frame_rate": lastPerformanceSnapshot.frameRate,
                "battery_level": lastPerformanceSnapshot.batteryLevel,
                "thermal_state": lastPerformanceSnapshot.thermalState.rawValue,
                "memory_usage_mb": Double(lastPerformanceSnapshot.memoryUsage) / 1024 / 1024,
                "is_promotion_active": lastPerformanceSnapshot.isProMotionActive
            ],
            "telemetry": telemetryData,
            "coordinator_summary": coordinatorSummary,
            "export_timestamp": Date().timeIntervalSince1970
        ]
    }
    
    /// Manual system status refresh
    func refreshSystemStatus() async {
        await updateSystemStatus()
        lastPerformanceSnapshot = .current()
        logger.debug("🔄 System status refreshed: \(self.currentStatus.description)")
    }
    
    /// Get real-time performance metrics for debugging
    func getRealTimeMetrics() async -> (restorations: Int, frameRate: Double, batteryLevel: Float, memoryMB: Double) {
        let memoryBytes = lastPerformanceSnapshot.memoryUsage
        let memoryMB = Double(memoryBytes) / 1024 / 1024
        
        return (
            restorations: totalRestorations,
            frameRate: lastPerformanceSnapshot.frameRate,
            batteryLevel: lastPerformanceSnapshot.batteryLevel,
            memoryMB: memoryMB
        )
    }
    
    // MARK: - Private Implementation
    
    private func setupSystemMonitoring() {
        // Monitor performance every 5 seconds
        performanceMonitor
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.updateSystemStatus()
                }
            }
            .store(in: &cancellables)
        
        // Monitor thermal state changes
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.updateSystemStatus()
                    self?.logger.debug("🌡️ Thermal state changed, updating system status")
                }
            }
            .store(in: &cancellables)
        
        // Monitor battery level changes
        NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.updateSystemStatus()
                }
            }
            .store(in: &cancellables)
        
        // Monitor memory warnings
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.logger.warning("⚠️ Memory warning received, updating system status")
                    await self?.updateSystemStatus()
                }
            }
            .store(in: &cancellables)
    }
    
    private func startPerformanceTracking() {
        // Start background telemetry collection
        Task {
            while !Task.isCancelled {
                // Collect system metrics every minute
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                // Record memory usage snapshot for telemetry
        let memorySnapshot = SystemPerformanceSnapshot.current()
        await telemetryActor.recordMemoryUsage(context: "periodic_snapshot")
            }
        }
    }
    
    private func updateSystemStatus() async {
        let snapshot = SystemPerformanceSnapshot.current()
        
        // Determine system status based on multiple factors
        let newStatus: IntegrationStatus
        
        // Check critical system resources
        let memoryPercentage = Double(snapshot.memoryUsage) / Double(ProcessInfo.processInfo.physicalMemory)
        let isBatteryLow = snapshot.batteryLevel < 0.2
        let isThermalThrottled = snapshot.thermalState == .serious || snapshot.thermalState == .critical
        let isMemoryConstrained = memoryPercentage > 0.8
        
        if isThermalThrottled || isMemoryConstrained {
            newStatus = .unavailable
        } else if isBatteryLow || memoryPercentage > 0.6 {
            newStatus = .fallback
        } else if snapshot.batteryLevel < 0.4 || snapshot.thermalState == .fair {
            newStatus = .degraded
        } else {
            newStatus = .optimal
        }
        
        if newStatus != currentStatus {
            logger.info("📊 System status changed: \(self.currentStatus.description) → \(newStatus.description)")
            
            // Track status changes for A/B testing
            self.abTestingFramework?.trackEvent(
                ExperimentEvent(
                    name: "system_status_change",
                    value: 1.0,
                    metadata: [
                        "from": self.currentStatus.description,
                        "to": newStatus.description,
                        "battery_level": snapshot.batteryLevel,
                        "memory_percentage": memoryPercentage,
                        "thermal_state": snapshot.thermalState.rawValue
                    ]
                ),
                for: "scroll_position_preservation_v2"
            )
        }
        
        currentStatus = newStatus
        lastPerformanceSnapshot = snapshot
    }
    
    private func updateTrackingMetrics(
        result: iOS18ScrollPreservationCoordinator.RestorationResult,
        preSnapshot: SystemPerformanceSnapshot,
        postSnapshot: SystemPerformanceSnapshot
    ) async {
        
        // Record comprehensive telemetry
        await telemetryActor.recordScrollRestoration(
            success: result.success,
            error: result.pixelError,
            frameRate: result.frameRate,
            duration: result.duration,
            updateLinkFrames: result.updateLinkFrames,
            scrollStrategy: result.strategy.description
        )
        
        // Track A/B testing conversion metrics
        if result.isHighQuality {
            abTestingFramework?.trackConversion(for: "scroll_position_preservation_v2")
        }
        
        // Track performance degradation if any
        let batteryDrop = preSnapshot.batteryLevel - postSnapshot.batteryLevel
        if batteryDrop > 0.01 { // 1% battery drop
            abTestingFramework?.trackPerformance(
                for: "scroll_position_preservation_v2",
                metric: "battery_impact",
                value: Double(batteryDrop)
            )
        }
        
        // Track memory usage changes
        let memoryDelta = Int64(postSnapshot.memoryUsage) - Int64(preSnapshot.memoryUsage)
        if abs(memoryDelta) > 1024 * 1024 { // 1MB change
            abTestingFramework?.trackPerformance(
                for: "scroll_position_preservation_v2",
                metric: "memory_delta_mb",
                value: Double(memoryDelta) / 1024 / 1024
            )
        }
    }
    
    deinit {
        cancellables.removeAll()
        performanceMonitor.upstream.connect().cancel()
    }
}

// MARK: - SwiftUI Integration

@available(iOS 18.0, *)
struct ScrollPreservationStatusView: View {
    @ObservedObject var integration: EnhancedScrollPreservationIntegration
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(integration.currentStatus.color)
                    .frame(width: 8, height: 8)
                
                Text("Scroll Preservation")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(integration.activeStrategy)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            
            if integration.totalRestorations > 0 {
                HStack {
                    Text("\(integration.totalRestorations) restorations")
                        .font(.caption2)
                    
                    Spacer()
                    
                    Text("\(Int(integration.successRate * 100))% success")
                        .font(.caption2)
                        .foregroundColor(integration.successRate > 0.95 ? .green : .orange)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground))
                .shadow(radius: 1)
        )
    }
}

// MARK: - Debug Views

@available(iOS 18.0, *)
struct ScrollPreservationDebugView: View {
    @ObservedObject var integration: EnhancedScrollPreservationIntegration
    @State private var isExpanded = false
    
    var body: some View {
        VStack {
            Button(action: {
                withAnimation {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    Text("Scroll Debug Info")
                        .font(.headline)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                }
            }
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    debugSection("System Status", value: integration.currentStatus.description)
                    debugSection("Frame Rate", value: "\(Int(integration.lastPerformanceSnapshot.frameRate))Hz")
                    debugSection("Battery Level", value: "\(Int(integration.lastPerformanceSnapshot.batteryLevel * 100))%")
                    debugSection("Memory Usage", value: "\(Int(Double(integration.lastPerformanceSnapshot.memoryUsage) / 1024 / 1024))MB")
                    debugSection("ProMotion Active", value: integration.lastPerformanceSnapshot.isProMotionActive ? "Yes" : "No")
                    debugSection("Success Rate", value: "\(Int(integration.successRate * 100))%")
                    
                    Button("Refresh Status") {
                        Task {
                            await integration.refreshSystemStatus()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.systemGray6))
                )
            }
        }
        .padding()
    }
    
    private func debugSection(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

#if DEBUG
@available(iOS 18.0, *)
struct ScrollPreservationDebugView_Previews: PreviewProvider {
    static var previews: some View {
        ScrollPreservationDebugView(
            integration: EnhancedScrollPreservationIntegration()
        )
    }
}
#endif
