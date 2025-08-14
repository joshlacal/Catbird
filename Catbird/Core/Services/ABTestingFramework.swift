import Foundation
import SwiftUI
import OSLog

// MARK: - ✅ iOS 18: A/B Testing Framework

/// ✅ iOS 18: Comprehensive A/B testing framework for feature experimentation
/// Provides type-safe experiment definitions, user bucketing, and performance tracking
@Observable
final class ABTestingFramework {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird.experiments", category: "ABTestingFramework")
    
    /// Current user's experiment assignments
    private(set) var userBuckets: [String: ExperimentVariant] = [:]
    
    /// Experiment definitions and configurations
    private var experimentConfigs: [String: ExperimentConfig] = [:]
    
    /// Performance metrics for each experiment
    private var experimentMetrics: [String: ExperimentMetrics] = [:]
    
    /// User identifier for consistent bucketing
    private var userIdentifier: String = ""
    
    /// Framework enabled state
    private(set) var isEnabled: Bool = false
    
    // MARK: - Initialization
    
    init() {
        logger.info("🧪 A/B Testing Framework initialized")
        setupDefaultExperiments()
    }
    
    /// Configure the framework with user identifier
    func configure(userIdentifier: String, enabled: Bool = true) {
        self.userIdentifier = userIdentifier
        self.isEnabled = enabled
        
        if enabled {
            assignUserToBuckets()
            logger.info("A/B Testing Framework configured for user: \(userIdentifier)")
        } else {
            logger.info("A/B Testing Framework disabled")
        }
    }
    
    // MARK: - Experiment Management
    
    /// Register a new experiment
    func registerExperiment(_ config: ExperimentConfig) {
        experimentConfigs[config.id] = config
        experimentMetrics[config.id] = ExperimentMetrics(experimentId: config.id)
        
        // Assign user to bucket if framework is enabled
        if isEnabled && !userIdentifier.isEmpty {
            assignUserToBucket(for: config)
        }
        
        logger.info("Registered experiment: \(config.id)")
    }
    
    /// Get variant for a specific experiment
    func getVariant(for experimentId: String) -> ExperimentVariant {
        guard isEnabled else { return .control }
        
        if let assigned = userBuckets[experimentId] {
            return assigned
        }
        
        // Return control if experiment not found or user not assigned
        return .control
    }
    
    /// Check if user is in treatment group for experiment
    func isInTreatment(for experimentId: String) -> Bool {
        return getVariant(for: experimentId) == .treatment
    }
    
    /// Check if user is in specific variant
    func isInVariant(for experimentId: String, variant: ExperimentVariant) -> Bool {
        return getVariant(for: experimentId) == variant
    }
    
    // MARK: - Event Tracking
    
    /// Track an event for experiment analysis
    func trackEvent(_ event: ExperimentEvent, for experimentId: String) {
        guard isEnabled,
              let metrics = experimentMetrics[experimentId],
              let variant = userBuckets[experimentId] else { return }
        
        metrics.recordEvent(event, variant: variant)
        
        logger.debug("Tracked event \(event.name) for experiment \(experimentId) variant \(variant.rawValue)")
    }
    
    /// Track conversion event (primary success metric)
    func trackConversion(for experimentId: String, value: Double = 1.0) {
        let event = ExperimentEvent(
            name: "conversion",
            value: value,
            metadata: ["timestamp": Date().timeIntervalSince1970]
        )
        trackEvent(event, for: experimentId)
    }
    
    /// Track performance metric
    func trackPerformance(for experimentId: String, metric: String, value: Double) {
        let event = ExperimentEvent(
            name: "performance_\(metric)",
            value: value,
            metadata: ["metric_type": metric]
        )
        trackEvent(event, for: experimentId)
    }
    
    // MARK: - Analytics & Reporting
    
    /// Get experiment results summary
    func getExperimentResults(for experimentId: String) -> ExperimentResults? {
        guard let config = experimentConfigs[experimentId],
              let metrics = experimentMetrics[experimentId] else { return nil }
        
        return ExperimentResults(
            experimentId: experimentId,
            config: config,
            metrics: metrics.generateReport()
        )
    }
    
    /// Get all experiment results
    func getAllExperimentResults() -> [ExperimentResults] {
        return experimentConfigs.keys.compactMap { getExperimentResults(for: $0) }
    }
    
    /// Export experiment data for analysis
    func exportExperimentData() -> [String: Any] {
        var exportData: [String: Any] = [:]
        
        exportData["user_identifier"] = userIdentifier
        exportData["user_buckets"] = userBuckets.mapValues { $0.rawValue }
        exportData["experiment_configs"] = experimentConfigs.mapValues { $0.toDictionary() }
        exportData["experiment_metrics"] = experimentMetrics.mapValues { $0.toDictionary() }
        exportData["export_timestamp"] = Date().timeIntervalSince1970
        
        return exportData
    }
    
    // MARK: - Private Implementation
    
    private func setupDefaultExperiments() {
        // ✅ iOS 18: Feed performance experiments
        registerExperiment(ExperimentConfig(
            id: "feed_uikit_vs_swiftui",
            name: "Feed Implementation: UIKit vs SwiftUI",
            description: "Compare UICollectionView performance vs native SwiftUI List",
            variants: [.control, .treatment],
            trafficAllocation: 0.1, // 10% of users
            isActive: true
        ))
        
        registerExperiment(ExperimentConfig(
            id: "scroll_position_preservation_v2",
            name: "Enhanced Scroll Position Preservation",
            description: "Test iOS 18 UIUpdateLink scroll preservation vs standard",
            variants: [.control, .treatment],
            trafficAllocation: 0.3,
            isActive: true
        ))
        
        registerExperiment(ExperimentConfig(
            id: "adaptive_frame_rate_optimization",
            name: "Adaptive Frame Rate Optimization",
            description: "Test ProMotion adaptive frame rates vs fixed 120Hz",
            variants: [.control, .treatment],
            trafficAllocation: 0.25,
            isActive: true
        ))
        
        registerExperiment(ExperimentConfig(
            id: "scroll_telemetry_collection",
            name: "Enhanced Scroll Performance Telemetry",
            description: "Test comprehensive telemetry vs basic metrics",
            variants: [.control, .treatment],
            trafficAllocation: 0.2,
            isActive: true
        ))
        
        registerExperiment(ExperimentConfig(
            id: "promotion_scroll_optimization",
            name: "ProMotion Display Scroll Optimization",
            description: "Test ProMotion-specific scroll enhancements vs standard",
            variants: [.control, .treatment],
            trafficAllocation: 0.15,
            isActive: true
        ))
        
        registerExperiment(ExperimentConfig(
            id: "prefetch_strategy",
            name: "Content Prefetching Strategy",
            description: "Test aggressive vs conservative prefetching",
            variants: [.control, .treatment],
            trafficAllocation: 0.15,
            isActive: true
        ))
        
        registerExperiment(ExperimentConfig(
            id: "memory_management_actor",
            name: "Actor-based Memory Management",
            description: "Test actor-based vs traditional memory management",
            variants: [.control, .treatment],
            trafficAllocation: 0.25,
            isActive: true
        ))
    }
    
    private func assignUserToBuckets() {
        for config in experimentConfigs.values {
            assignUserToBucket(for: config)
        }
    }
    
    private func assignUserToBucket(for config: ExperimentConfig) {
        guard config.isActive else {
            userBuckets[config.id] = .control
            return
        }
        
        // Use consistent hashing for deterministic bucketing
        let seed = "\(userIdentifier):\(config.id)"
        let hash = seed.hash
        let normalizedHash = abs(Double(hash)) / Double(Int.max)
        
        if normalizedHash < config.trafficAllocation {
            // User is in experiment, randomly assign to variant
            let variantHash = "\(seed):variant".hash
            let variantNormalized = abs(Double(variantHash)) / Double(Int.max)
            
            if variantNormalized < 0.5 {
                userBuckets[config.id] = .control
            } else {
                userBuckets[config.id] = .treatment
            }
        } else {
            // User not in experiment
            userBuckets[config.id] = .control
        }
        
        logger.debug("Assigned user to variant \(self.userBuckets[config.id]?.rawValue ?? "none") for experiment \(config.id)")
    }
}

// MARK: - Experiment Configuration

struct ExperimentConfig {
    let id: String
    let name: String
    let description: String
    let variants: [ExperimentVariant]
    let trafficAllocation: Double // 0.0 to 1.0
    let isActive: Bool
    
    func toDictionary() -> [String: Any] {
        return [
            "id": id,
            "name": name,
            "description": description,
            "variants": variants.map { $0.rawValue },
            "traffic_allocation": trafficAllocation,
            "is_active": isActive
        ]
    }
}

enum ExperimentVariant: String, CaseIterable {
    case control = "control"
    case treatment = "treatment"
    case variantA = "variant_a"
    case variantB = "variant_b"
    case variantC = "variant_c"
}

// MARK: - Event Tracking

struct ExperimentEvent {
    let name: String
    let value: Double
    let metadata: [String: Any]
    let timestamp: Date
    
    init(name: String, value: Double = 1.0, metadata: [String: Any] = [:]) {
        self.name = name
        self.value = value
        self.metadata = metadata
        self.timestamp = Date()
    }
}

// MARK: - Metrics & Analytics

class ExperimentMetrics {
    let experimentId: String
    private var eventsByVariant: [ExperimentVariant: [ExperimentEvent]] = [:]
    private var conversionsByVariant: [ExperimentVariant: Double] = [:]
    private var performanceMetrics: [ExperimentVariant: [String: [Double]]] = [:]
    
    init(experimentId: String) {
        self.experimentId = experimentId
    }
    
    func recordEvent(_ event: ExperimentEvent, variant: ExperimentVariant) {
        eventsByVariant[variant, default: []].append(event)
        
        // Track conversions separately
        if event.name == "conversion" {
            conversionsByVariant[variant, default: 0] += event.value
        }
        
        // Track performance metrics
        if event.name.hasPrefix("performance_") {
            let metricName = String(event.name.dropFirst("performance_".count))
            performanceMetrics[variant, default: [:]][metricName, default: []].append(event.value)
        }
    }
    
    func generateReport() -> ExperimentMetricsReport {
        var variantReports: [ExperimentVariant: VariantMetrics] = [:]
        
        for variant in ExperimentVariant.allCases {
            let events = eventsByVariant[variant] ?? []
            let conversions = conversionsByVariant[variant] ?? 0
            let performance = performanceMetrics[variant] ?? [:]
            
            variantReports[variant] = VariantMetrics(
                eventCount: events.count,
                conversionTotal: conversions,
                conversionRate: events.isEmpty ? 0 : conversions / Double(events.count),
                performanceMetrics: performance.mapValues { values in
                    PerformanceMetric(
                        count: values.count,
                        average: values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count),
                        min: values.min() ?? 0,
                        max: values.max() ?? 0
                    )
                }
            )
        }
        
        return ExperimentMetricsReport(
            experimentId: experimentId,
            variantMetrics: variantReports,
            generatedAt: Date()
        )
    }
    
    func toDictionary() -> [String: Any] {
        let report = generateReport()
        return [
            "experiment_id": experimentId,
            "variant_metrics": report.variantMetrics.mapValues { metrics in
                [
                    "event_count": metrics.eventCount,
                    "conversion_total": metrics.conversionTotal,
                    "conversion_rate": metrics.conversionRate,
                    "performance_metrics": metrics.performanceMetrics.mapValues { perf in
                        [
                            "count": perf.count,
                            "average": perf.average,
                            "min": perf.min,
                            "max": perf.max
                        ]
                    }
                ]
            },
            "generated_at": report.generatedAt.timeIntervalSince1970
        ]
    }
}

struct ExperimentMetricsReport {
    let experimentId: String
    let variantMetrics: [ExperimentVariant: VariantMetrics]
    let generatedAt: Date
}

struct VariantMetrics {
    let eventCount: Int
    let conversionTotal: Double
    let conversionRate: Double
    let performanceMetrics: [String: PerformanceMetric]
}

struct PerformanceMetric {
    let count: Int
    let average: Double
    let min: Double
    let max: Double
}

// MARK: - Results & Reporting

struct ExperimentResults {
    let experimentId: String
    let config: ExperimentConfig
    let metrics: ExperimentMetricsReport
    
    /// Statistical significance test (simplified)
    var hasStatisticalSignificance: Bool {
        let controlMetrics = metrics.variantMetrics[.control]
        let treatmentMetrics = metrics.variantMetrics[.treatment]
        
        guard let control = controlMetrics,
              let treatment = treatmentMetrics,
              control.eventCount > 30,
              treatment.eventCount > 30 else {
            return false // Need sufficient sample size
        }
        
        // Simplified significance test - in production, use proper statistical tests
        let controlRate = control.conversionRate
        let treatmentRate = treatment.conversionRate
        let relativeDifference = abs(treatmentRate - controlRate) / controlRate
        
        return relativeDifference > 0.05 // 5% relative difference threshold
    }
    
    /// Recommended action based on results
    var recommendation: String {
        guard hasStatisticalSignificance else {
            return "Continue experiment - insufficient data for decision"
        }
        
        let controlConversion = metrics.variantMetrics[.control]?.conversionRate ?? 0
        let treatmentConversion = metrics.variantMetrics[.treatment]?.conversionRate ?? 0
        
        if treatmentConversion > controlConversion {
            return "Ship treatment - statistically significant improvement"
        } else {
            return "Ship control - treatment shows no improvement"
        }
    }
}

// MARK: - SwiftUI Integration

/// ✅ iOS 18: SwiftUI view modifier for A/B testing
struct ExperimentVariantModifier: ViewModifier {
    let experimentId: String
    let framework: ABTestingFramework
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                framework.trackEvent(
                    ExperimentEvent(name: "view_appeared"),
                    for: experimentId
                )
            }
    }
}

extension View {
    /// Track experiment view appearance
    func trackExperiment(_ experimentId: String, framework: ABTestingFramework) -> some View {
        modifier(ExperimentVariantModifier(experimentId: experimentId, framework: framework))
    }
    
    /// Conditional content based on experiment variant
    @ViewBuilder
    func experimentVariant<Control: View, Treatment: View>(
        _ experimentId: String,
        framework: ABTestingFramework,
        @ViewBuilder control: () -> Control,
        @ViewBuilder treatment: () -> Treatment
    ) -> some View {
        if framework.isInTreatment(for: experimentId) {
            treatment()
                .trackExperiment(experimentId, framework: framework)
        } else {
            control()
                .trackExperiment(experimentId, framework: framework)
        }
    }
}

// MARK: - Performance Testing Utilities

/// ✅ iOS 18: Performance measurement utilities for A/B testing
class ABPerformanceMeasurement {
    private let framework: ABTestingFramework
    private let experimentId: String
    private let startTime: CFAbsoluteTime
    
    init(framework: ABTestingFramework, experimentId: String) {
        self.framework = framework
        self.experimentId = experimentId
        self.startTime = CFAbsoluteTimeGetCurrent()
    }
    
    /// Complete measurement and track performance
    func complete(operation: String) {
        let duration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000 // milliseconds
        framework.trackPerformance(
            for: experimentId,
            metric: operation,
            value: duration
        )
    }
}

extension ABTestingFramework {
    /// Start performance measurement
    func startPerformanceMeasurement(for experimentId: String) -> ABPerformanceMeasurement {
        return ABPerformanceMeasurement(framework: self, experimentId: experimentId)
    }
    
    /// Measure the performance of a code block
    func measurePerformance<T>(
        for experimentId: String,
        operation: String,
        block: () throws -> T
    ) rethrows -> T {
        let measurement = startPerformanceMeasurement(for: experimentId)
        let result = try block()
        measurement.complete(operation: operation)
        return result
    }
    
    /// Measure async performance
    func measureAsyncPerformance<T>(
        for experimentId: String,
        operation: String,
        block: () async throws -> T
    ) async rethrows -> T {
        let measurement = startPerformanceMeasurement(for: experimentId)
        let result = try await block()
        measurement.complete(operation: operation)
        return result
    }
}
