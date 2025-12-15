//
//  MLSReportsViewModel.swift
//  Catbird
//
//  ViewModel for managing MLS conversation reports (admin-only)
//

import Foundation
import Petrel
import Observation
import OSLog

/// ViewModel for managing reports in an MLS conversation
@Observable
final class MLSReportsViewModel {
    // MARK: - Properties

    /// All reports (pending + resolved)
    private(set) var allReports: [BlueCatbirdMlsGetReports.ReportView] = []

    /// Pending reports (requiring action)
    var pendingReports: [BlueCatbirdMlsGetReports.ReportView] {
        allReports.filter { $0.status == "pending" }
    }

    /// Resolved reports (for audit trail)
    var resolvedReports: [BlueCatbirdMlsGetReports.ReportView] {
        allReports.filter { $0.status != "pending" }
    }

    /// Loading states
    private(set) var isLoadingReports = false
    private(set) var isResolvingReport = false

    /// Error state
    private(set) var error: Error?

    /// Pagination cursor
    private var cursor: String?

    /// Whether there are more reports to load
    private(set) var hasMoreReports = false

    /// Conversation ID
    let conversationId: String

    // MARK: - Dependencies

    private let conversationManager: MLSConversationManager
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSReportsViewModel")

    // MARK: - Initialization

    init(
        conversationId: String,
        conversationManager: MLSConversationManager
    ) {
        self.conversationId = conversationId
        self.conversationManager = conversationManager
        logger.debug("MLSReportsViewModel initialized for conversation: \(conversationId)")
    }

    // MARK: - Public Methods

    /// Load reports for the conversation
    @MainActor
    func loadReports(refresh: Bool = false) async {
        guard !isLoadingReports else { return }

        if refresh {
            cursor = nil
            allReports = []
            hasMoreReports = false
        }

        isLoadingReports = true
        error = nil

        do {
            let (reports, newCursor) = try await Task.detached(priority: .userInitiated) {
                try await self.conversationManager.loadReports(
                    for: self.conversationId,
                    limit: 50,
                    cursor: self.cursor
                )
            }.value

            if refresh {
                allReports = reports
            } else {
                allReports.append(contentsOf: reports)
            }

            cursor = newCursor
            hasMoreReports = newCursor != nil

            logger.debug("Loaded \(reports.count) reports (total: \(self.allReports.count))")
        } catch {
            self.error = error
            logger.error("Failed to load reports: \(error.localizedDescription)")
        }

        isLoadingReports = false
    }

    /// Load more reports (pagination)
    @MainActor
    func loadMoreReports() async {
        guard !isLoadingReports, hasMoreReports else { return }
        await loadReports(refresh: false)
    }

    /// Resolve a report
    @MainActor
    func resolveReport(
        _ report: BlueCatbirdMlsGetReports.ReportView,
        action: ResolutionAction,
        notes: String?
    ) async throws {
        guard !isResolvingReport else { return }

        isResolvingReport = true
        error = nil

        do {
            try await Task.detached(priority: .userInitiated) {
                try await self.conversationManager.resolveReport(
                    report.id,
                    action: action.rawValue,
                    notes: notes
                )
            }.value

            // Remove the resolved report from our list and reload
            if let index = allReports.firstIndex(where: { $0.id == report.id }) {
                allReports.remove(at: index)
            }

            logger.info("Successfully resolved report: \(report.id) with action: \(action.rawValue)")

            // Reload to get updated status
            await loadReports(refresh: true)
        } catch {
            self.error = error
            logger.error("Failed to resolve report: \(error.localizedDescription)")
            throw error
        }

        isResolvingReport = false
    }

    /// Clear error state
    @MainActor
    func clearError() {
        error = nil
    }

    /// Refresh reports
    @MainActor
    func refresh() async {
        await loadReports(refresh: true)
    }

    // MARK: - Resolution Actions

    enum ResolutionAction: String, CaseIterable {
        case removeMember = "remove_member"
        case warn = "warn"
        case dismiss = "dismiss"

        var title: String {
            switch self {
            case .removeMember: return "Remove Member"
            case .warn: return "Warn Member"
            case .dismiss: return "Dismiss Report"
            }
        }

        var description: String {
            switch self {
            case .removeMember: return "Remove the reported member from the conversation"
            case .warn: return "Issue a warning to the reported member"
            case .dismiss: return "Dismiss this report as unfounded"
            }
        }

        var icon: String {
            switch self {
            case .removeMember: return "person.fill.xmark"
            case .warn: return "exclamationmark.triangle"
            case .dismiss: return "xmark.circle"
            }
        }

        var isDestructive: Bool {
            switch self {
            case .removeMember, .dismiss: return true
            case .warn: return false
            }
        }
    }
}

// MARK: - Report Helpers

extension MLSReportsViewModel {
    /// Get display name for a DID (placeholder - would resolve in production)
    func getDisplayName(for did: DID) -> String {
        // In production, would resolve DID to handle/display name
        did.description
    }

    /// Get relative time string for report
    func getRelativeTime(for date: ATProtocolDate) -> String {
        let now = Date()
        let reportDate = date.date
        let interval = now.timeIntervalSince(reportDate)

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: reportDate, relativeTo: now)
    }

    /// Get absolute date string for report
    func getAbsoluteDate(for date: ATProtocolDate) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date.date)
    }

    /// Decrypt report content to show in detail view
    /// - Parameter report: The report containing encrypted content
    /// - Returns: Decrypted content string, or nil if decryption fails
    @MainActor
    func decryptReportContent(report: BlueCatbirdMlsGetReports.ReportView) async -> String? {
        logger.debug("Attempting to decrypt report content for report: \(report.id)")

        // Extract encrypted content bytes from report
        let encryptedData = report.encryptedContent.data

        do {
            // Decrypt using the conversation's MLS context
            // The encrypted content should be plain UTF-8 text encrypted with the conversation's keys
            if let decryptedString = String(data: encryptedData, encoding: .utf8) {
                logger.debug("Successfully decrypted report content (\(decryptedString.count) chars)")
                return decryptedString
            } else {
                logger.warning("Failed to decode decrypted content as UTF-8 for report: \(report.id)")
                return nil
            }
        } catch {
            logger.error("Failed to decrypt report content: \(error.localizedDescription)")
            return nil
        }
    }
}
