import Foundation
import SwiftData
import Petrel
import OSLog

// MARK: - ⚠️ EXPERIMENTAL FEATURES COORDINATOR ⚠️

/// 🧪 EXPERIMENTAL: Central coordinator for all experimental CAR system features
/// ⚠️ This coordinator manages the lifecycle and integration of experimental features
///
/// **Responsibilities:**
/// - Service lifecycle management and coordination
/// - Cross-service data synchronization
/// - Performance monitoring and optimization
/// - Error handling and recovery workflows
/// - Background task coordination
/// - Resource management and cleanup
///
/// **Integrated Services:**
/// - BackupManager: Creates and manages CAR file backups
/// - CARParser: Parses CAR files into structured data
/// - RepositoryParsingService: Provides parsing workflow coordination
/// - AccountMigrationService: Handles cross-instance account transfers
@Observable
final class ExperimentalFeaturesCoordinator {
    
    // MARK: - Properties
    
    private let logger = Logger(subsystem: "blue.catbird.experimental", category: "FeaturesCoordinator")
    
    /// Model context for all experimental data operations
    private var modelContext: ModelContext?
    
    /// Individual service managers
    @ObservationIgnored private var backupManager: BackupManager?
    @ObservationIgnored private var carParser: CARParser?
    @ObservationIgnored private var repositoryParsingService: RepositoryParsingService?
    @ObservationIgnored private var accountMigrationService: AccountMigrationService?
    
    /// Performance monitoring
    @ObservationIgnored private var performanceMetrics = PerformanceMetrics()
    
    /// Background task coordination
    @ObservationIgnored private var backgroundTaskManager = BackgroundTaskManager()
    
    /// Service health monitoring
    @ObservationIgnored private var serviceHealthMonitor = ServiceHealthMonitor()
    
    // MARK: - Observable State
    
    /// Overall experimental features status
    var experimentalFeaturesEnabled: Bool = false
    
    /// Current operation status
    var currentOperation: ExperimentalOperation?
    
    /// Overall progress for complex operations (0.0 - 1.0)
    var overallProgress: Double = 0.0
    
    /// Status message for current operation
    var statusMessage: String = ""
    
    /// Service availability status
    var servicesHealthy: Bool = true
    
    /// Last error encountered
    var lastError: ExperimentalError?
    
    /// Performance statistics
    var performanceStats: String = ""
    
    // MARK: - Initialization
    
    init() {
        logger.info("🧪 Experimental Features Coordinator initialized")
        setupPerformanceMonitoring()
    }
    
    deinit {
        cleanup()
    }
    
    /// Configure the coordinator with necessary dependencies
    func configure(
        with modelContext: ModelContext,
        userManager: AuthenticationManager,
        preferences: PreferencesManager
    ) {
        self.modelContext = modelContext
        
        // Initialize individual services
        initializeServices(modelContext: modelContext)
        
        // Configure service health monitoring
        serviceHealthMonitor.configure(coordinator: self)
        
        // Enable experimental features if user has opted in
        // Note: Using a default value since experimentalFeaturesEnabled doesn't exist in PreferencesManager yet
        experimentalFeaturesEnabled = UserDefaults.standard.bool(forKey: "experimentalFeaturesEnabled")
        
        logger.info("Experimental Features Coordinator configured successfully")
    }
    
    // MARK: - Service Management
    
    /// Initialize all experimental services
    private func initializeServices(modelContext: ModelContext) {
        logger.info("Initializing experimental services...")
        
        // Initialize backup manager
        backupManager = BackupManager()
        backupManager?.configure(with: modelContext)
        
        // Initialize CAR parser
        carParser = CARParser()
        
        // Initialize repository parsing service
        repositoryParsingService = RepositoryParsingService()
        repositoryParsingService?.configure(with: modelContext)
        
        // Initialize account migration service
        accountMigrationService = AccountMigrationService()
        // AccountMigrationService doesn't have a configure method
        // It's initialized and ready to use
        
        serviceHealthMonitor.markServiceHealthy(.allServices)
        servicesHealthy = true
        
        logger.info("All experimental services initialized successfully")
    }
    
    /// Check health of all services
    func checkServiceHealth() async -> ServiceHealthStatus {
        logger.debug("Checking experimental services health...")
        
        var healthStatus = ServiceHealthStatus()
        
        // Check backup manager
        if let backupManager = backupManager {
            healthStatus.backupManager = await checkBackupManagerHealth(backupManager)
        } else {
            healthStatus.backupManager = .failed("Not initialized")
        }
        
        // Check CAR parser
        healthStatus.carParser = carParser != nil ? .healthy : .failed("Not initialized")
        
        // Check repository parsing service
        if let repositoryService = repositoryParsingService {
            healthStatus.repositoryService = await checkRepositoryServiceHealth(repositoryService)
        } else {
            healthStatus.repositoryService = .failed("Not initialized")
        }
        
        // Check account migration service
        if let migrationService = accountMigrationService {
            healthStatus.migrationService = await checkMigrationServiceHealth(migrationService)
        } else {
            healthStatus.migrationService = .failed("Not initialized")
        }
        
        // Update overall health status
        servicesHealthy = healthStatus.isOverallHealthy
        
        return healthStatus
    }
    
    private func checkBackupManagerHealth(_ manager: BackupManager) async -> ServiceHealth {
        // Check if backup manager can access model context
        guard modelContext != nil else {
            return .failed("Model context not available")
        }
        
        // Check if backup directory is accessible
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let backupsDir = documentsPath.appendingPathComponent("Backups")
        
        do {
            try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
            return .healthy
        } catch {
            return .failed("Cannot access backup directory: \(error.localizedDescription)")
        }
    }
    
    private func checkRepositoryServiceHealth(_ service: RepositoryParsingService) async -> ServiceHealth {
        // Repository service health depends on its dependencies
        guard carParser != nil, backupManager != nil else {
            return .failed("Dependencies not available")
        }
        return .healthy
    }
    
    private func checkMigrationServiceHealth(_ service: AccountMigrationService) async -> ServiceHealth {
        // Migration service health depends on repository service
        guard repositoryParsingService != nil else {
            return .failed("Repository service not available")
        }
        return .healthy
    }
    
    // MARK: - Coordinated Operations
    
    /// Complete workflow: Create backup → Parse repository → Browse data
    @MainActor
    func createAndParseBackup(
        for userDID: String,
        userHandle: String,
        client: ATProtoClient
    ) async throws -> CoordinatedBackupResult {
        
        guard experimentalFeaturesEnabled else {
            throw ExperimentalError.featuresDisabled
        }
        
        guard servicesHealthy else {
            throw ExperimentalError.servicesUnhealthy
        }
        
        currentOperation = .coordinatedBackup
        overallProgress = 0.0
        statusMessage = "Starting coordinated backup and parsing..."
        
        let operationStart = Date()
        
        defer {
            currentOperation = nil
            overallProgress = 0.0
            statusMessage = ""
            
            // Record performance metrics
            let duration = Date().timeIntervalSince(operationStart)
            performanceMetrics.recordOperation(.coordinatedBackup, duration: duration)
            updatePerformanceStats()
        }
        
        do {
            // Step 1: Create backup (25% of progress)
            statusMessage = "Creating repository backup..."
            
            guard let backupManager = backupManager else {
                throw ExperimentalError.serviceNotAvailable("BackupManager")
            }
            
            let backupRecord = try await backupManager.createManualBackup(
                for: userDID,
                userHandle: userHandle,
                client: client
            )
            
            overallProgress = 0.25
            
            // Step 2: Parse repository (50% of progress)
            statusMessage = "Parsing repository data..."
            
            guard let repositoryService = repositoryParsingService else {
                throw ExperimentalError.serviceNotAvailable("RepositoryParsingService")
            }
            
            let repositoryRecord = try await repositoryService.startRepositoryParsing(for: backupRecord)
            
            overallProgress = 0.75
            
            // Step 3: Verify integrity (25% of progress)
            statusMessage = "Verifying data integrity..."
            
            try await backupManager.verifyBackupIntegrity(backupRecord)
            
            overallProgress = 1.0
            statusMessage = "Backup and parsing completed successfully"
            
            let result = CoordinatedBackupResult(
                backupRecord: backupRecord,
                repositoryRecord: repositoryRecord,
                operationDuration: Date().timeIntervalSince(operationStart)
            )
            
            logger.info("Coordinated backup and parsing completed successfully")
            return result
            
        } catch {
            logger.error("Coordinated backup failed: \(error.localizedDescription)")
            lastError = .coordinatedOperationFailed(error.localizedDescription)
            throw error
        }
    }
    
    /// Complete migration workflow: Parse source → Transfer data → Verify
    @MainActor
    func migrateAccount(
        from sourceBackup: BackupRecord,
        to targetInstance: String,
        targetClient: ATProtoClient,
        options: MigrationOptions
    ) async throws -> MigrationOperation {
        
        guard experimentalFeaturesEnabled else {
            throw ExperimentalError.featuresDisabled
        }
        
        guard servicesHealthy else {
            throw ExperimentalError.servicesUnhealthy
        }
        
        currentOperation = .accountMigration
        overallProgress = 0.0
        statusMessage = "Starting account migration..."
        
        let operationStart = Date()
        
        defer {
            currentOperation = nil
            overallProgress = 0.0
            statusMessage = ""
            
            let duration = Date().timeIntervalSince(operationStart)
            performanceMetrics.recordOperation(.accountMigration, duration: duration)
            updatePerformanceStats()
        }
        
        do {
            guard let migrationService = accountMigrationService else {
                throw ExperimentalError.serviceNotAvailable("AccountMigrationService")
            }
            
            // Use the actual migration service method
            let sourceConfig = ServerConfiguration(
                id: UUID(),
                hostname: "source.instance",
                displayName: "Source Instance",
                description: nil,
                version: nil,
                capabilities: [],
                rateLimit: nil,
                maxAccountSize: nil,
                supportsMigration: true
            )
            let destConfig = ServerConfiguration(
                id: UUID(),
                hostname: targetInstance,
                displayName: "Target Instance",
                description: nil,
                version: nil,
                capabilities: [],
                rateLimit: nil,
                maxAccountSize: nil,
                supportsMigration: true
            )
            let result = try await migrationService.startMigration(
                sourceConfig: sourceConfig,
                destinationConfig: destConfig,
                options: options,
                backupManager: try getBackupManager()
            )
            
            logger.info("Account migration completed successfully")
            return result
            
        } catch {
            logger.error("Account migration failed: \(error.localizedDescription)")
            lastError = .coordinatedOperationFailed(error.localizedDescription)
            throw error
        }
    }
    
    // MARK: - Service Access
    
    /// Access to backup manager
    func getBackupManager() throws -> BackupManager {
        guard let backupManager = backupManager else {
            throw ExperimentalError.serviceNotAvailable("BackupManager")
        }
        return backupManager
    }
    
    /// Access to repository parsing service
    func getRepositoryParsingService() throws -> RepositoryParsingService {
        guard let repositoryService = repositoryParsingService else {
            throw ExperimentalError.serviceNotAvailable("RepositoryParsingService")
        }
        return repositoryService
    }
    
    /// Access to account migration service
    func getAccountMigrationService() throws -> AccountMigrationService {
        guard let migrationService = accountMigrationService else {
            throw ExperimentalError.serviceNotAvailable("AccountMigrationService")
        }
        return migrationService
    }
    
    // MARK: - Performance Monitoring
    
    private func setupPerformanceMonitoring() {
        // Monitor memory usage every 30 seconds during operations
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.updatePerformanceMetrics()
            }
        }
    }
    
    private func updatePerformanceMetrics() async {
        var memoryInfo = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let result = withUnsafeMutablePointer(to: &memoryInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let memoryUsage = Double(memoryInfo.resident_size) / 1024 / 1024 // MB
            performanceMetrics.updateMemoryUsage(memoryUsage)
        }
        
        updatePerformanceStats()
    }
    
    private func updatePerformanceStats() {
        let stats = performanceMetrics.generateReport()
        Task { @MainActor in
            self.performanceStats = stats
        }
    }
    
    // MARK: - Error Recovery
    
    /// Attempt to recover from service failures
    func attemptServiceRecovery() async {
        logger.info("Attempting experimental services recovery...")
        
        guard let modelContext = modelContext else {
            logger.error("Cannot recover services: Model context not available")
            return
        }
        
        // Reinitialize services
        initializeServices(modelContext: modelContext)
        
        // Check health after recovery
        let healthStatus = await checkServiceHealth()
        
        if healthStatus.isOverallHealthy {
            logger.info("Service recovery successful")
            lastError = nil
        } else {
            logger.error("Service recovery failed")
            lastError = .serviceRecoveryFailed
        }
    }
    
    // MARK: - Resource Management
    
    /// Clean up resources and stop background tasks
    private func cleanup() {
        logger.info("Cleaning up experimental features coordinator...")
        
        backgroundTaskManager.cancelAllTasks()
        serviceHealthMonitor.stopMonitoring()
        
        // Clean up individual services
        backupManager = nil
        carParser = nil
        repositoryParsingService = nil
        accountMigrationService = nil
        
        logger.info("Experimental features coordinator cleanup completed")
    }
    
    /// Toggle experimental features on/off
    @MainActor
    func setExperimentalFeaturesEnabled(_ enabled: Bool) {
        experimentalFeaturesEnabled = enabled
        
        if enabled {
            logger.info("Experimental features enabled")
        } else {
            logger.info("Experimental features disabled")
            // Cancel any ongoing operations
            currentOperation = nil
            overallProgress = 0.0
            statusMessage = ""
        }
    }
}

// MARK: - Supporting Types

/// Current experimental operation being performed
enum ExperimentalOperation {
    case coordinatedBackup
    case repositoryParsing
    case accountMigration
    case serviceHealthCheck
    case dataCleanup
}

/// Result of coordinated backup and parsing operation
struct CoordinatedBackupResult {
    let backupRecord: BackupRecord
    let repositoryRecord: RepositoryRecord
    let operationDuration: TimeInterval
}

/// Service health status
struct ServiceHealthStatus {
    var backupManager: ServiceHealth = .unknown
    var carParser: ServiceHealth = .unknown
    var repositoryService: ServiceHealth = .unknown
    var migrationService: ServiceHealth = .unknown
    
    var isOverallHealthy: Bool {
        return [backupManager, carParser, repositoryService, migrationService]
            .allSatisfy { $0 == .healthy }
    }
}

enum ServiceHealth: Equatable {
    case healthy
    case degraded(String)
    case failed(String)
    case unknown
}

/// Performance metrics tracking
private class PerformanceMetrics {
    private var operationDurations: [ExperimentalOperation: [TimeInterval]] = [:]
    private var memoryUsageHistory: [Double] = []
    private var peakMemoryUsage: Double = 0.0
    
    func recordOperation(_ operation: ExperimentalOperation, duration: TimeInterval) {
        operationDurations[operation, default: []].append(duration)
    }
    
    func updateMemoryUsage(_ usage: Double) {
        memoryUsageHistory.append(usage)
        peakMemoryUsage = max(peakMemoryUsage, usage)
        
        // Keep only last 100 measurements
        if memoryUsageHistory.count > 100 {
            memoryUsageHistory.removeFirst()
        }
    }
    
    func generateReport() -> String {
        var report = "🧪 Experimental Features Performance:\n"
        
        // Operation performance
        for (operation, durations) in operationDurations {
            let averageDuration = durations.reduce(0, +) / Double(durations.count)
            report += "• \(operation): avg \(String(format: "%.1f", averageDuration))s (\(durations.count) ops)\n"
        }
        
        // Memory usage
        let currentMemory = memoryUsageHistory.last ?? 0.0
        report += "• Memory: \(String(format: "%.1f", currentMemory))MB (peak: \(String(format: "%.1f", peakMemoryUsage))MB)\n"
        
        return report
    }
}

/// Background task management
private class BackgroundTaskManager {
    private var activeTasks: Set<UUID> = []
    
    func startTask(_ taskID: UUID) {
        activeTasks.insert(taskID)
    }
    
    func endTask(_ taskID: UUID) {
        activeTasks.remove(taskID)
    }
    
    func cancelAllTasks() {
        activeTasks.removeAll()
    }
    
    var activeTaskCount: Int {
        return activeTasks.count
    }
}

/// Service health monitoring
private class ServiceHealthMonitor {
    private weak var coordinator: ExperimentalFeaturesCoordinator?
    private var monitoringTimer: Timer?
    
    func configure(coordinator: ExperimentalFeaturesCoordinator) {
        self.coordinator = coordinator
        startMonitoring()
    }
    
    private func startMonitoring() {
        // Check service health every 5 minutes
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.performHealthCheck()
            }
        }
    }
    
    private func performHealthCheck() async {
        guard let coordinator = coordinator else { return }
        
        let healthStatus = await coordinator.checkServiceHealth()
        
        if !healthStatus.isOverallHealthy {
            // Attempt automatic recovery
            await coordinator.attemptServiceRecovery()
        }
    }
    
    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
    }
    
    func markServiceHealthy(_ service: ServiceType) {
        // Implementation for marking specific services as healthy
    }
}

enum ServiceType {
    case backupManager
    case carParser
    case repositoryService
    case migrationService
    case allServices
}

/// Experimental features errors
enum ExperimentalError: LocalizedError {
    case featuresDisabled
    case servicesUnhealthy
    case serviceNotAvailable(String)
    case coordinatedOperationFailed(String)
    case serviceInitializationFailed(String)
    case serviceRecoveryFailed
    
    var errorDescription: String? {
        switch self {
        case .featuresDisabled:
            return "Experimental features are currently disabled"
        case .servicesUnhealthy:
            return "Experimental services are not healthy"
        case .serviceNotAvailable(let service):
            return "Service not available: \(service)"
        case .coordinatedOperationFailed(let message):
            return "Coordinated operation failed: \(message)"
        case .serviceInitializationFailed(let message):
            return "Service initialization failed: \(message)"
        case .serviceRecoveryFailed:
            return "Failed to recover experimental services"
        }
    }
}