import CatbirdMLSCore
//
//  MLSAdminDashboardView.swift
//  Catbird
//
//  Admin dashboard for MLS conversation management
//

import SwiftUI
import Petrel
import OSLog

@available(iOS 26.0, macOS 26.0, *)
struct MLSAdminDashboardView: View {
    // MARK: - Dependencies

    let conversationId: String
    let apiClient: MLSAPIClient
    let conversationManager: MLSConversationManager

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var viewModel: MLSAdminDashboardViewModel?
    @State private var showingError = false
    @State private var errorMessage: String?
    @State private var isAuthorized = false
    @State private var isCheckingAccess = true

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSAdminDashboard")

    // MARK: - Body

    var body: some View {
        Group {
            if isCheckingAccess {
                ProgressView("Checking admin access…")
            } else if !isAuthorized {
                unauthorizedView
            } else if let viewModel = viewModel {
                dashboardContent(viewModel: viewModel)
            } else {
                ProgressView("Loading Dashboard...")
            }
        }
        .navigationTitle("Admin Dashboard")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
            }
        }
        .task {
            if isCheckingAccess {
                isAuthorized = await conversationManager.isCurrentUserAdmin(of: conversationId)
                isCheckingAccess = false
            }

            guard isAuthorized else { return }

            if viewModel == nil {
                viewModel = MLSAdminDashboardViewModel(
                    conversationId: conversationId,
                    apiClient: apiClient,
                    conversationManager: conversationManager
                )
                await viewModel?.loadDashboard()
            }
        }
        .refreshable {
            await viewModel?.refresh()
        }
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage = errorMessage {
                Text(errorMessage)
            }
        }
    }

    private var unauthorizedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Admin dashboard is restricted to conversation admins.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Dashboard Content

    @ViewBuilder
    private func dashboardContent(viewModel: MLSAdminDashboardViewModel) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                // Last refresh indicator
                if let refreshTime = viewModel.lastRefreshDate {
                    HStack {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("Last updated: \(viewModel.getLastRefreshString())")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
                }

                // Alert banner (if issues exist)
                if viewModel.hasIssues {
                    alertBanner(viewModel: viewModel)
                }

                // Overview stats
                if let stats = viewModel.adminStats {
                    overviewSection(stats: stats, viewModel: viewModel)
                }

                // Key package health
                if let keyStats = viewModel.keyPackageStats {
                    keyPackageSection(stats: keyStats, viewModel: viewModel)
                }

                // Member activity
                if let stats = viewModel.adminStats {
                    memberActivitySection(stats: stats, viewModel: viewModel)
                }
            }
            .padding()
        }
        .background(Color.systemGroupedBackground)
    }

    // MARK: - Alert Banner

    @ViewBuilder
    private func alertBanner(viewModel: MLSAdminDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Attention Required")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                if viewModel.keyPackageHealth != .healthy {
                    Label("Key package health: \(viewModel.keyPackageHealth.title)", systemImage: viewModel.keyPackageHealth.icon)
                        .font(.caption)
                }

            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.orange.opacity(0.1))
        .glassEffect(.regular.tint(.orange))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Overview Section

    @ViewBuilder
    private func overviewSection(stats: BlueCatbirdMlsChatUpdateConvo.Output, viewModel: MLSAdminDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Overview")
                .font(.headline)
                .padding(.horizontal)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 16) {
                StatCard(
                    title: "Success",
                    value: stats.success ? "Yes" : "No",
                    icon: "checkmark.circle.fill",
                    color: stats.success ? .green : .red
                )

                if let epoch = stats.newEpoch {
                    StatCard(
                        title: "Epoch",
                        value: "\(epoch)",
                        icon: "number.circle.fill",
                        color: .blue
                    )
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Key Package Section

    @ViewBuilder
    private func keyPackageSection(stats: BlueCatbirdMlsChatPublishKeyPackages.Output, viewModel: MLSAdminDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Key Package Health")
                    .font(.headline)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: viewModel.keyPackageHealth.icon)
                    Text(viewModel.keyPackageHealth.title)
                }
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(viewModel.keyPackageHealth.color).opacity(0.15))
                .foregroundStyle(Color(viewModel.keyPackageHealth.color))
                .clipShape(Capsule())
            }
            .padding(.horizontal)

            VStack(spacing: 8) {
                HStack {
                    Text("Published: \(stats.stats.published)")
                        .font(.caption)
                    Spacer()
                    Text("Available: \(stats.stats.available)")
                        .font(.caption)
                    Spacer()
                    Text("Expired: \(stats.stats.expired)")
                        .font(.caption)
                }
                .padding()
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Member Activity Section

    @ViewBuilder
    private func memberActivitySection(stats: BlueCatbirdMlsChatUpdateConvo.Output, viewModel: MLSAdminDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)
                .padding(.horizontal)

            VStack(spacing: 8) {
                if let epoch = stats.newEpoch {
                    ActivityRow(
                        label: "Current Epoch",
                        value: epoch,
                        icon: "number.circle.fill",
                        color: .blue
                    )
                }

                if let policy = stats.policy {
                    let maxMembers = policy.maxMembers
                    ActivityRow(
                        label: "Max Members",
                        value: maxMembers,
                        icon: "person.3.fill",
                        color: .purple
                    )
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Stat Card Component

@available(iOS 26.0, macOS 26.0, *)
private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1))
        .glassEffect(.regular.interactive())
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Key Package Summary (Replaces per-cipher-suite KeyPackageRow)
// Consolidated publishKeyPackages no longer provides CipherSuiteStats breakdown

// MARK: - Activity Row Component

@available(iOS 26.0, macOS 26.0, *)
private struct ActivityRow: View {
    let label: String
    let value: Int
    let icon: String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 40)

            Text(label)
                .font(.subheadline)

            Spacer()

            Text("\(value)")
                .font(.headline)
                .fontWeight(.semibold)
        }
        .padding()
        .background(color.opacity(0.1))
        .glassEffect()
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
