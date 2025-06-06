import Foundation
import OSLog
import UIKit

/// Service for ensuring migration safety and handling emergencies
class MigrationSafetyService {
  private let logger = Logger(subsystem: "blue.catbird", category: "MigrationSafety")
  
  // Migration tracking
  private var currentMigration: MigrationOperation?
  private var lastStatusChange: Date?
  
  // MARK: - Safety Checks
  
  /// Perform comprehensive pre-migration safety checks
  func performPreMigrationSafetyCheck(
    migration: MigrationOperation,
    compatibilityReport: CompatibilityReport
  ) async throws -> SafetyReport {
    
    logger.info("🛡️ Performing pre-migration safety check")
    
    var risks: [SafetyRisk] = []
    var recommendations: [String] = []
    var blockers: [String] = []
    
    // Check compatibility risk level
    switch compatibilityReport.riskLevel {
    case .critical:
      blockers.append("Critical compatibility issues detected - migration cannot proceed safely")
    case .high:
      risks.append(SafetyRisk(
        level: .high,
        category: .compatibility,
        description: "High compatibility risk detected",
        mitigation: "Consider using minimal migration options"
      ))
    case .medium:
      risks.append(SafetyRisk(
        level: .medium,
        category: .compatibility,
        description: "Medium compatibility risk",
        mitigation: "Proceed with caution and verify migration carefully"
      ))
    case .low:
      break
    }
    
    // Check data size risks
    if migration.estimatedDataSize > 1024 * 1024 * 50 { // 50MB
      risks.append(SafetyRisk(
        level: .medium,
        category: .dataSize,
        description: "Large data migration detected",
        mitigation: "Migration may take significant time - ensure stable connection"
      ))
    }
    
    if migration.estimatedDataSize > 1024 * 1024 * 200 { // 200MB
      risks.append(SafetyRisk(
        level: .high,
        category: .dataSize,
        description: "Very large data migration",
        mitigation: "Consider using selective migration options to reduce data size"
      ))
    }
    
    // Check server stability (mock check)
    let serverStability = await checkServerStability(migration: migration)
    if !serverStability.sourceStable {
      risks.append(SafetyRisk(
        level: .high,
        category: .serverStability,
        description: "Source server showing instability",
        mitigation: "Wait for server stability before proceeding"
      ))
    }
    
    if !serverStability.destinationStable {
      risks.append(SafetyRisk(
        level: .high,
        category: .serverStability,
        description: "Destination server showing instability",
        mitigation: "Wait for server stability before proceeding"
      ))
    }
    
    // Generate recommendations
    if migration.options.includeMedia && migration.estimatedDataSize > 1024 * 1024 * 100 {
      recommendations.append("Consider excluding media files to speed up migration")
    }
    
    if !migration.options.createBackupBeforeMigration {
      recommendations.append("⚠️ Strongly recommend enabling backup before migration")
    }
    
    if !migration.options.verifyAfterMigration {
      recommendations.append("Enable post-migration verification for safety")
    }
    
    // Determine overall safety level
    let overallLevel = determineOverallSafetyLevel(risks: risks, blockers: blockers)
    
    return SafetyReport(
      overallLevel: overallLevel,
      canProceed: blockers.isEmpty,
      risks: risks,
      blockers: blockers,
      recommendations: recommendations,
      estimatedRiskScore: calculateRiskScore(risks: risks),
      checkedAt: Date()
    )
  }
  
  /// Monitor migration for safety issues during execution
  func monitorMigrationSafety(migration: MigrationOperation) async -> SafetyMonitor {
    logger.info("🔍 Starting migration safety monitoring")
    
    let monitor = SafetyMonitor(migration: migration, safetyService: self)
    migration.safetyMonitor = monitor // Will be stored as AnyObject
    return monitor
  }
  
  /// Handle emergency stop during migration
  func emergencyStop(migration: MigrationOperation, reason: String) async {
    logger.critical("🚨 EMERGENCY STOP: \(reason)")
    
    migration.updateStatus(.failed)
    migration.errorMessage = "Emergency stop: \(reason)"
    
    // Attempt to clean up any partial state
    await performEmergencyCleanup(migration: migration)
  }
  
  // MARK: - Private Methods
  
  private func checkServerStability(migration: MigrationOperation) async -> (sourceStable: Bool, destinationStable: Bool) {
    // Mock implementation - would implement actual server health checks
    // Could check response times, error rates, etc.
    
    // For demonstration, assume servers are stable
    return (sourceStable: true, destinationStable: true)
  }
  
  private func determineOverallSafetyLevel(risks: [SafetyRisk], blockers: [String]) -> SafetyLevel {
    if !blockers.isEmpty {
      return .critical
    }
    
    let highRisks = risks.filter { $0.level == .high }.count
    let mediumRisks = risks.filter { $0.level == .medium }.count
    
    if highRisks > 0 {
      return .high
    } else if mediumRisks > 1 {
      return .medium
    } else if mediumRisks > 0 {
      return .low
    } else {
      return .safe
    }
  }
  
  private func calculateRiskScore(risks: [SafetyRisk]) -> Double {
    let totalScore = risks.reduce(0.0) { total, risk in
      total + risk.level.score
    }
    
    // Normalize to 0-1 scale (assuming max 10 high risks = score of 1.0)
    return min(totalScore / 10.0, 1.0)
  }
  
  private func performEmergencyCleanup(migration: MigrationOperation) async {
    logger.info("Performing emergency cleanup")
    
    // Clean up temporary files
    if let exportPath = migration.exportedDataPath {
      try? FileManager.default.removeItem(atPath: exportPath)
    }
    
    // Would implement additional cleanup logic
    // - Cancel ongoing requests
    // - Clean up partial imports
    // - Reset connection states
  }
}

// MARK: - Safety Monitoring

/// Real-time safety monitoring during migration
class SafetyMonitor: NSObject {
  private let migration: MigrationOperation
  private let safetyService: MigrationSafetyService
  private let safetyLogger = Logger(subsystem: "blue.catbird", category: "SafetyMonitor")
  
  // Monitoring state
  private var isMonitoring = false
  private var monitoringTask: Task<Void, Never>?
  private var lastKnownStatus: MigrationStatus?
  
  // Safety thresholds
  private let maxResponseTime: TimeInterval = 30.0
  private let maxConsecutiveErrors = 3
  private let maxMigrationDuration: TimeInterval = 3600.0 // 1 hour
  
  init(migration: MigrationOperation, safetyService: MigrationSafetyService) {
    self.migration = migration
    self.safetyService = safetyService
    super.init()
  }
  
  func startMonitoring() {
    guard !isMonitoring else { return }
    
    isMonitoring = true
      safetyLogger.info("🔍 Starting safety monitoring for migration \(self.migration.id)")
    
    monitoringTask = Task { [weak self] in
      await self?.performContinuousMonitoring()
    }
  }
  
  func stopMonitoring() {
    isMonitoring = false
    monitoringTask?.cancel()
    monitoringTask = nil
    
    safetyLogger.info("⏹️ Stopped safety monitoring")
  }
  
  private func performContinuousMonitoring() async {
    let checkInterval: TimeInterval = 10.0 // Check every 10 seconds
    
    // Initialize with current status
    lastKnownStatus = migration.status
    updateStatusTimestamp()
    
    while isMonitoring && !Task.isCancelled {
      // Check for status changes
      if migration.status != lastKnownStatus {
        safetyLogger.info("Migration status changed from \(String(describing: self.lastKnownStatus)) to \(self.migration.status.rawValue)")
        lastKnownStatus = migration.status
        updateStatusTimestamp()
      }
      
      // Check migration duration
      let migrationDuration = Date().timeIntervalSince(migration.createdAt)
      if migrationDuration > maxMigrationDuration {
        await safetyService.emergencyStop(
          migration: migration,
          reason: "Migration exceeded maximum duration (\(Int(maxMigrationDuration/60)) minutes)"
        )
        break
      }
      
      // Check for stuck progress
      if await isProgressStuck() {
        safetyLogger.warning("⚠️ Migration progress appears stuck")
        await handleStuckProgress()
      }
      
      // Check system resources
      if await isSystemUnderStress() {
        safetyLogger.warning("⚠️ System resources under stress")
        await handleSystemStress()
      }
      
      try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
    }
  }
  
  private func isProgressStuck() async -> Bool {
    guard let lastStatusChange = lastStatusChange else {
      return false // No status recorded yet
    }
    
    let stuckThreshold: TimeInterval = 300 // 5 minutes without progress
    let timeSinceLastChange = Date().timeIntervalSince(lastStatusChange)
    
    if timeSinceLastChange > stuckThreshold {
      safetyLogger.warning("Migration appears stuck - no progress for \(timeSinceLastChange) seconds")
      return true
    }
    
    // Additional check: if we're in a processing state but no activity
    if migration.status == .validating || migration.status == .exporting || migration.status == .importing {
      let activityThreshold: TimeInterval = 120 // 2 minutes without activity
      if timeSinceLastChange > activityThreshold {
        safetyLogger.warning("Migration in progress but inactive for \(timeSinceLastChange) seconds")
        return await checkForActiveProcessing()
      }
    }
    
    return false
  }
  
  private func isSystemUnderStress() async -> Bool {
    var stressFactors: [String] = []
    
    // Check memory pressure
    let memoryPressure = await checkMemoryPressure()
    if memoryPressure > 0.8 {
      stressFactors.append("High memory usage: \(Int(memoryPressure * 100))%")
    }
    
    // Check available disk space
    let diskSpaceAvailable = await checkDiskSpace()
    if diskSpaceAvailable < 100_000_000 { // Less than 100MB
      stressFactors.append("Low disk space: \(diskSpaceAvailable / 1_000_000)MB remaining")
    }
    
    // Check for background app state
    let isInBackground = await checkAppState()
    if isInBackground {
      stressFactors.append("App is in background")
    }
    
    // Check network connectivity
    let hasConnectivity = await checkNetworkConnectivity()
    if !hasConnectivity {
      stressFactors.append("No network connectivity")
    }
    
    if !stressFactors.isEmpty {
      safetyLogger.warning("System stress detected: \(stressFactors.joined(separator: ", "))")
      return true
    }
    
    return false
  }
  
  // MARK: - System Health Checks
  
  private var lastStatusChange: Date?
  
  private func updateStatusTimestamp() {
    lastStatusChange = Date()
  }
  
  private func checkForActiveProcessing() async -> Bool {
    // Check if migration processes are actually running
    // This could check for file I/O activity, network requests, etc.
    
    // Simulate checking for actual processing activity
    // In reality, this would check:
    // - File system activity in temp directories
    // - Network requests to migration APIs
    // - CPU usage by migration threads
    
    return false // Simplified: assume no active processing if we're checking
  }
  
  private func checkMemoryPressure() async -> Double {
    // Get memory information
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
    
    let kerr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_,
                  task_flavor_t(MACH_TASK_BASIC_INFO),
                  $0,
                  &count)
      }
    }
    
    if kerr == KERN_SUCCESS {
      let memoryUsed = Double(info.resident_size)
      let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
      return memoryUsed / memoryTotal
    }
    
    return 0.0 // Unable to determine, assume low usage
  }
  
  private func checkDiskSpace() async -> Int64 {
    do {
      let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
      let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      return values.volumeAvailableCapacityForImportantUsage ?? 0
    } catch {
      safetyLogger.error("Failed to check disk space: \(error.localizedDescription)")
      return 0
    }
  }
  
  private func checkAppState() async -> Bool {
    return await MainActor.run {
      UIApplication.shared.applicationState == .background
    }
  }
  
  private func checkNetworkConnectivity() async -> Bool {
    // Simple network connectivity check
    guard let url = URL(string: "https://httpbin.org/status/200") else {
      return false
    }
    
    do {
      let (_, response) = try await URLSession.shared.data(from: url)
      if let httpResponse = response as? HTTPURLResponse {
        return httpResponse.statusCode == 200
      }
    } catch {
      safetyLogger.debug("Network connectivity check failed: \(error.localizedDescription)")
    }
    
    return false
  }
  
  /// Notify the monitor of external status changes
  @objc func notifyStatusChange() {
    if migration.status != lastKnownStatus {
      safetyLogger.info("External status change detected: \(String(describing: self.lastKnownStatus)) -> \(self.migration.status.rawValue)")
      lastKnownStatus = migration.status
      updateStatusTimestamp()
    }
  }
  
  // MARK: - Safety Response Actions
  
  /// Handle stuck progress by attempting automatic recovery
  private func handleStuckProgress() async {
    safetyLogger.warning("Attempting to recover from stuck migration progress")
    
    // Log current state for debugging
    safetyLogger.info("Migration stuck details: Status=\(self.migration.status.rawValue), Phase=\(self.migration.currentPhase), Progress=\(self.migration.progress)")
    
    // For now, we'll just log the issue
    // In a full implementation, this could:
    // - Retry the current operation
    // - Skip to the next phase if possible
    // - Request user intervention
    // - Trigger emergency stop if critical
    
    // Reset the timestamp to give it more time
    updateStatusTimestamp()
  }
  
  /// Handle system stress by adjusting migration parameters
  private func handleSystemStress() async {
    safetyLogger.warning("Handling system stress during migration")
    
    // For now, we'll just log and slow down
    // In a full implementation, this could:
    // - Reduce batch sizes
    // - Pause migration temporarily
    // - Clear caches to free memory
    // - Notify user of performance impact
    
    // Add a small delay to reduce system load
    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
  }
  
  deinit {
    stopMonitoring()
  }
}

// MARK: - Safety Models

struct SafetyReport {
  let overallLevel: SafetyLevel
  let canProceed: Bool
  let risks: [SafetyRisk]
  let blockers: [String]
  let recommendations: [String]
  let estimatedRiskScore: Double // 0.0 to 1.0
  let checkedAt: Date
}

struct SafetyRisk {
  let level: SafetyLevel
  let category: RiskCategory
  let description: String
  let mitigation: String
  
  enum RiskCategory: String, CaseIterable {
    case compatibility = "compatibility"
    case dataSize = "data_size"
    case serverStability = "server_stability"
    case authentication = "authentication"
    case network = "network"
    case timing = "timing"
    
    var displayName: String {
      switch self {
      case .compatibility: return "Compatibility"
      case .dataSize: return "Data Size"
      case .serverStability: return "Server Stability"
      case .authentication: return "Authentication"
      case .network: return "Network"
      case .timing: return "Timing"
      }
    }
    
    var systemImage: String {
      switch self {
      case .compatibility: return "checkmark.shield"
      case .dataSize: return "internaldrive"
      case .serverStability: return "server.rack"
      case .authentication: return "lock.shield"
      case .network: return "network"
      case .timing: return "clock"
      }
    }
  }
}

enum SafetyLevel: String, CaseIterable {
  case safe = "safe"
  case low = "low"
  case medium = "medium"
  case high = "high"
  case critical = "critical"
  
  var displayName: String {
    switch self {
    case .safe: return "Safe"
    case .low: return "Low Risk"
    case .medium: return "Medium Risk"
    case .high: return "High Risk"
    case .critical: return "Critical Risk"
    }
  }
  
  var color: String {
    switch self {
    case .safe: return "green"
    case .low: return "blue"
    case .medium: return "yellow"
    case .high: return "orange"
    case .critical: return "red"
    }
  }
  
  var systemImage: String {
    switch self {
    case .safe: return "checkmark.shield.fill"
    case .low: return "shield"
    case .medium: return "exclamationmark.shield"
    case .high: return "exclamationmark.triangle.fill"
    case .critical: return "xmark.shield.fill"
    }
  }
  
  var score: Double {
    switch self {
    case .safe: return 0.0
    case .low: return 0.2
    case .medium: return 0.5
    case .high: return 0.8
    case .critical: return 1.0
    }
  }
}
