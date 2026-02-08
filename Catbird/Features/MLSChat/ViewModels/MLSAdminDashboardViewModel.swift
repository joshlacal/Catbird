import CatbirdMLSService
//
//  MLSAdminDashboardViewModel.swift
//  Catbird
//
//  ViewModel for MLS conversation admin dashboard
//

import Foundation
import Petrel
import Observation
import OSLog

/// ViewModel for managing admin dashboard data
@Observable
final class MLSAdminDashboardViewModel {
    // MARK: - Properties

    /// Admin statistics
    private(set) var adminStats: BlueCatbirdMlsGetAdminStats.Output?

    /// Key package statistics
    private(set) var keyPackageStats: BlueCatbirdMlsGetKeyPackageStats.Output?

    /// Pending reports count
    private(set) var pendingReportsCount = 0

    /// Loading states
    private(set) var isLoadingStats = false
    private(set) var isLoadingKeyPackages = false
    private(set) var isLoadingReports = false

    /// Error state
    private(set) var error: Error?

    /// Last refresh timestamp
    private(set) var lastRefreshDate: Date?

    /// Conversation ID
    let conversationId: String

    // MARK: - Dependencies

    private let apiClient: MLSAPIClient
    private let conversationManager: MLSConversationManager
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSAdminDashboard")

    // MARK: - Initialization

    init(
        conversationId: String,
        apiClient: MLSAPIClient,
        conversationManager: MLSConversationManager
    ) {
        self.conversationId = conversationId
        self.apiClient = apiClient
        self.conversationManager = conversationManager
        logger.debug("MLSAdminDashboardViewModel initialized for conversation: \(conversationId)")
    }

    // MARK: - Public Methods

    /// Load all dashboard data
    @MainActor
    func loadDashboard() async {
        guard !isLoadingStats else { return }

        error = nil

        // Load all data in parallel
        async let statsTask = loadAdminStats()
        async let keyPackagesTask = loadKeyPackageStats()
        async let reportsTask = loadPendingReportsCount()

        await statsTask
        await keyPackagesTask
        await reportsTask

        lastRefreshDate = Date()
    }

    /// Load admin statistics
    @MainActor
    private func loadAdminStats() async {
        guard !isLoadingStats else { return }

        isLoadingStats = true

        do {
            let stats = try await Task.detached(priority: .userInitiated) {
                try await self.apiClient.getAdminStats(convoId: self.conversationId)
            }.value
            adminStats = stats
            logger.debug("Loaded admin stats for conversation: \(self.conversationId)")
        } catch {
            self.error = error
            logger.error("Failed to load admin stats: \(error.localizedDescription)")
        }

        isLoadingStats = false
    }

    /// Load key package statistics
    @MainActor
    private func loadKeyPackageStats() async {
        guard !isLoadingKeyPackages else { return }

        isLoadingKeyPackages = true

        do {
            let stats = try await Task.detached(priority: .userInitiated) {
                try await self.apiClient.getKeyPackageStats()
            }.value
            keyPackageStats = stats
            logger.debug("Loaded key package stats for conversation: \(self.conversationId)")
        } catch {
            self.error = error
            logger.error("Failed to load key package stats: \(error.localizedDescription)")
        }

        isLoadingKeyPackages = false
    }

    /// Load pending reports count
    @MainActor
    private func loadPendingReportsCount() async {
        // TODO: Re-enable when reports feature is implemented on server
        pendingReportsCount = 0
        isLoadingReports = false
        return
        
        /* Reports disabled - uncomment when ready
        guard !isLoadingReports else { return }

        isLoadingReports = true

        do {
            // Load first page of reports to get count
            let (reports, _) = try await Task.detached(priority: .userInitiated) {
                try await self.conversationManager.loadReports(
                    for: self.conversationId,
                    limit: 50,
                    cursor: nil as String?
                )
            }.value

            pendingReportsCount = reports.filter { $0.status == "pending" }.count
            logger.debug("Loaded \(self.pendingReportsCount) pending reports")
        } catch {
            self.error = error
            logger.error("Failed to load reports: \(error.localizedDescription)")
        }

        isLoadingReports = false
        */
    }

    /// Refresh all data
    @MainActor
    func refresh() async {
        await loadDashboard()
    }

    /// Clear error state
    @MainActor
    func clearError() {
        error = nil
    }

    // MARK: - Computed Properties

    /// Whether any loading is in progress
    var isLoading: Bool {
        isLoadingStats || isLoadingKeyPackages || isLoadingReports
    }

    /// Key package health status
    var keyPackageHealth: HealthStatus {
        guard let stats = keyPackageStats else { return .unknown }

        let availableCount = stats.available
        let threshold = stats.threshold

        if availableCount == 0 {
            return .critical
        } else if availableCount < threshold {
            return .warning
        } else {
            return .healthy
        }
    }

    /// Whether there are any pending reports
    var hasPendingReports: Bool {
        pendingReportsCount > 0
    }

    /// Whether there are any issues requiring attention
    var hasIssues: Bool {
        keyPackageHealth != .healthy || hasPendingReports
    }

    // MARK: - Health Status

    enum HealthStatus {
        case healthy
        case warning
        case critical
        case unknown

        var color: String {
            switch self {
            case .healthy: return "green"
            case .warning: return "orange"
            case .critical: return "red"
            case .unknown: return "gray"
            }
        }

        var icon: String {
            switch self {
            case .healthy: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .critical: return "xmark.circle.fill"
            case .unknown: return "questionmark.circle.fill"
            }
        }

        var title: String {
            switch self {
            case .healthy: return "Healthy"
            case .warning: return "Warning"
            case .critical: return "Critical"
            case .unknown: return "Unknown"
            }
        }
    }
}

// MARK: - Formatting Helpers

extension MLSAdminDashboardViewModel {
    /// Format large numbers (e.g., 1000 -> "1K")
    func formatCount(_ count: Int) -> String {
        if count < 1000 {
            return "\(count)"
        } else if count < 1_000_000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        } else {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
    }

    /// Format percentage
    func formatPercentage(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    /// Get relative time string for last refresh
    func getLastRefreshString() -> String {
        guard let date = lastRefreshDate else { return "Never" }

        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
    }
}

// MARK: - Chart Data Helpers

extension MLSAdminDashboardViewModel {
    /// Get member activity data for chart (joins vs leaves)
    func getMemberActivityData() -> [(label: String, joins: Int, leaves: Int)] {
        guard let stats = adminStats else { return [] }

        // For now, show simplified data
        // In production, would have daily breakdown from API
        return [
            ("Today", 0, 0) // memberActivity is not available in Output
        ]
    }

    /// Get key package distribution data
    func getKeyPackageDistribution() -> [(cipherSuite: String, available: Int, consumed: Int)] {
        guard let stats = keyPackageStats,
              let byCipherSuite = stats.byCipherSuite else { return [] }

        return byCipherSuite.map { stat in
            (
                cipherSuite: stat.cipherSuite,
                available: stat.available,
                consumed: stat.consumed ?? 0
            )
        }
    }
}
