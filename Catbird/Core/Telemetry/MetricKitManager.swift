import Foundation
import MetricKit
import OSLog

/// MetricKitManager integrates Apple's MetricKit framework for collecting performance
/// and diagnostic data throughout the Catbird app.
///
/// Features:
/// - Subscribes to daily metric and diagnostic payloads
/// - Tracks extended launch measurements
/// - Provides custom signpost logging for key operations
/// - Persists metrics for analysis
@MainActor
final class MetricKitManager: NSObject, @unchecked Sendable {
  
  // MARK: - Singleton
  
  static let shared = MetricKitManager()
  
  // MARK: - Properties
  
  private let metricLogger = Logger(subsystem: "blue.catbird", category: "MetricKit")
  private var isSubscribed = false
  
  /// Custom metric log handles for various app operations
  private(set) var feedLoadingLog: OSLog?
  private(set) var imageLoadingLog: OSLog?
  private(set) var networkRequestLog: OSLog?
  private(set) var authenticationLog: OSLog?
  private(set) var composerLog: OSLog?
  private(set) var mlsOperationLog: OSLog?
  
  // MARK: - Launch Task IDs
  
  /// Task ID for extended launch measurement tracking
  private var launchTaskID: MXLaunchTaskID?
  
  // MARK: - Initialization
  
  private override init() {
    super.init()
    setupLogHandles()
  }
  
  // MARK: - Setup
  
  /// Sets up custom metric log handles for signpost-based metrics
  private func setupLogHandles() {
    feedLoadingLog = MXMetricManager.makeLogHandle(category: "FeedLoading")
    imageLoadingLog = MXMetricManager.makeLogHandle(category: "ImageLoading")
    networkRequestLog = MXMetricManager.makeLogHandle(category: "NetworkRequest")
    authenticationLog = MXMetricManager.makeLogHandle(category: "Authentication")
    composerLog = MXMetricManager.makeLogHandle(category: "Composer")
    mlsOperationLog = MXMetricManager.makeLogHandle(category: "MLSOperation")
    
    metricLogger.info("✅ MetricKit log handles created")
  }
  
  /// Starts the MetricKit manager and subscribes to metric payloads
  func start() {
    guard !isSubscribed else {
      metricLogger.debug("MetricKit already subscribed")
      return
    }
    
    MXMetricManager.shared.add(self)
    isSubscribed = true
    metricLogger.info("✅ MetricKit manager started and subscribed")
    
    // Process any pending payloads from previous sessions
    processPastPayloads()
  }
  
  /// Stops the MetricKit manager
  func stop() {
    guard isSubscribed else { return }
    
    MXMetricManager.shared.remove(self)
    isSubscribed = false
    metricLogger.info("MetricKit manager stopped")
  }
  
  // MARK: - Extended Launch Measurement
  
  /// Begins extended launch measurement for post-first-frame initialization
  /// Call this after the first frame is drawn but before the app is fully ready
  func beginExtendedLaunchMeasurement(taskName: String = "AppInitialization") {
    let taskID = MXLaunchTaskID(taskName)
    launchTaskID = taskID
    
    do {
      try MXMetricManager.extendLaunchMeasurement(forTaskID: taskID)
      metricLogger.info("📊 Extended launch measurement started: \(taskName)")
    } catch {
      metricLogger.error("Failed to start extended launch measurement: \(error.localizedDescription)")
    }
  }
  
  /// Finishes extended launch measurement
  /// Call this when the app is fully initialized and ready for interaction
  func finishExtendedLaunchMeasurement() {
    guard let taskID = launchTaskID else {
      metricLogger.warning("No active launch measurement to finish")
      return
    }
    
    do {
      try MXMetricManager.finishExtendedLaunchMeasurement(forTaskID: taskID)
      metricLogger.info("📊 Extended launch measurement finished")
      launchTaskID = nil
    } catch {
      metricLogger.error("Failed to finish extended launch measurement: \(error.localizedDescription)")
    }
  }
  
  // MARK: - Past Payloads
  
  /// Processes any payloads received while the app wasn't running
  private func processPastPayloads() {
    let metricPayloads = MXMetricManager.shared.pastPayloads
    let diagnosticPayloads = MXMetricManager.shared.pastDiagnosticPayloads
    
    if !metricPayloads.isEmpty {
      metricLogger.info("📊 Processing \(metricPayloads.count) past metric payloads")
      processMetricPayloads(metricPayloads)
    }
    
    if !diagnosticPayloads.isEmpty {
      metricLogger.info("🔍 Processing \(diagnosticPayloads.count) past diagnostic payloads")
      processDiagnosticPayloads(diagnosticPayloads)
    }
  }
  
  // MARK: - Payload Processing
  
  private func processMetricPayloads(_ payloads: [MXMetricPayload]) {
    for payload in payloads {
      logMetricSummary(payload)
      persistMetricPayload(payload)
    }
  }
  
  private func processDiagnosticPayloads(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads {
      logDiagnosticSummary(payload)
      persistDiagnosticPayload(payload)
    }
  }
  
  private func logMetricSummary(_ payload: MXMetricPayload) {
    let begin = payload.timeStampBegin
    let end = payload.timeStampEnd
    let version = payload.latestApplicationVersion
    
    metricLogger.info("""
      📊 Metric Payload Summary:
      - Period: \(begin) to \(end)
      - App Version: \(version)
      """)
    
    // Log launch metrics if available
    if let launchMetrics = payload.applicationLaunchMetrics {
      metricLogger.info("  Launch: time to first draw available")
      
      // Log extended launch data if available
      let extendedLaunch = launchMetrics.histogrammedExtendedLaunch
      if extendedLaunch.totalBucketCount > 0 {
        metricLogger.info("  Extended launch histogram buckets: \(extendedLaunch.totalBucketCount)")
      }
    }
    
    // Log responsiveness metrics
    if let responsiveness = payload.applicationResponsivenessMetrics {
      let hangTime = responsiveness.histogrammedApplicationHangTime
      if hangTime.totalBucketCount > 0 {
        metricLogger.info("  Hang time buckets: \(hangTime.totalBucketCount)")
      }
    }
    
    // Log memory metrics
    if let memoryMetrics = payload.memoryMetrics {
      let peak = memoryMetrics.peakMemoryUsage
      metricLogger.info("  Peak memory: \(peak)")
    }
    
    // Log custom signpost metrics
    if let signpostMetrics = payload.signpostMetrics {
      for metric in signpostMetrics {
        metricLogger.info("  Signpost '\(metric.signpostName)': \(metric.totalCount) occurrences")
      }
    }
  }
  
  private func logDiagnosticSummary(_ payload: MXDiagnosticPayload) {
    let begin = payload.timeStampBegin
    let end = payload.timeStampEnd
    
    metricLogger.info("""
      🔍 Diagnostic Payload Summary:
      - Period: \(begin) to \(end)
      """)
    
    // Log crash diagnostics
    if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
      metricLogger.warning("  ⚠️ \(crashes.count) crash diagnostic(s)")
      for crash in crashes {
        if let reason = crash.terminationReason {
          metricLogger.warning("    Crash reason: \(reason)")
        }
      }
    }
    
    // Log hang diagnostics
    if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
      metricLogger.warning("  ⚠️ \(hangs.count) hang diagnostic(s)")
      for hang in hangs {
        metricLogger.warning("    Hang duration: \(hang.hangDuration)")
      }
    }
    
    // Log CPU exception diagnostics
    if let cpuExceptions = payload.cpuExceptionDiagnostics, !cpuExceptions.isEmpty {
      metricLogger.warning("  ⚠️ \(cpuExceptions.count) CPU exception(s)")
    }
    
    // Log disk write exception diagnostics
    if let diskExceptions = payload.diskWriteExceptionDiagnostics, !diskExceptions.isEmpty {
      metricLogger.warning("  ⚠️ \(diskExceptions.count) disk write exception(s)")
    }
    
    // Log app launch diagnostics
    if let launchDiagnostics = payload.appLaunchDiagnostics, !launchDiagnostics.isEmpty {
      metricLogger.warning("  ⚠️ \(launchDiagnostics.count) app launch diagnostic(s)")
    }
  }
  
  // MARK: - Persistence
  
  private func persistMetricPayload(_ payload: MXMetricPayload) {
    Task {
      do {
        let data = payload.jsonRepresentation()
        let directory = try metricsDirectory()
        let filename = "metric_\(ISO8601DateFormatter().string(from: payload.timeStampEnd)).json"
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url)
        metricLogger.debug("Persisted metric payload to \(url.lastPathComponent)")
      } catch {
        metricLogger.error("Failed to persist metric payload: \(error.localizedDescription)")
      }
    }
  }
  
  private func persistDiagnosticPayload(_ payload: MXDiagnosticPayload) {
    Task {
      do {
        let data = payload.jsonRepresentation()
        let directory = try metricsDirectory()
        let filename = "diagnostic_\(ISO8601DateFormatter().string(from: payload.timeStampEnd)).json"
        let url = directory.appendingPathComponent(filename)
        try data.write(to: url)
        metricLogger.debug("Persisted diagnostic payload to \(url.lastPathComponent)")
      } catch {
        metricLogger.error("Failed to persist diagnostic payload: \(error.localizedDescription)")
      }
    }
  }
  
  private func metricsDirectory() throws -> URL {
    let directory = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MetricKit", isDirectory: true)
    
    if !FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    
    return directory
  }
}

// MARK: - MXMetricManagerSubscriber

extension MetricKitManager: MXMetricManagerSubscriber {
  
  nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
    Task { @MainActor in
      metricLogger.info("📊 Received \(payloads.count) metric payload(s)")
      processMetricPayloads(payloads)
    }
  }
  
  nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
    Task { @MainActor in
      metricLogger.info("🔍 Received \(payloads.count) diagnostic payload(s)")
      processDiagnosticPayloads(payloads)
    }
  }
}
