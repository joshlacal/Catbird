//
//  MLSReportsView.swift
//  Catbird
//
//  Admin interface for reviewing and resolving member reports
//
//  NOTE: Deprecated/hidden while MLS moderation relies on direct removals.

import SwiftUI
import Petrel
import OSLog

#if os(iOS)

@available(iOS 26.0, *)
struct MLSReportsView: View {
    // MARK: - Dependencies

    let conversationId: String
    let conversationManager: MLSConversationManager

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var viewModel: MLSReportsViewModel?
    @State private var selectedReport: IdentifiableReport?
    @State private var showingResolutionSheet = false
    @State private var showingError = false
    @State private var errorMessage: String?
    @State private var isAuthorized = false
    @State private var isCheckingAccess = true

    // Wrapper to make ReportView Identifiable for sheet presentation
    private struct IdentifiableReport: Identifiable {
        let id: String
        let report: BlueCatbirdMlsGetReports.ReportView

        init(_ report: BlueCatbirdMlsGetReports.ReportView) {
            self.id = report.id
            self.report = report
        }
    }

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSReportsView")

    // MARK: - Body

    var body: some View {
        Group {
            if isCheckingAccess {
                ProgressView("Checking admin access…")
            } else if !isAuthorized {
                unauthorizedView
            } else if let viewModel = viewModel {
                reportsList(viewModel: viewModel)
            } else {
                ProgressView("Loading...")
            }
        }
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
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
                viewModel = MLSReportsViewModel(
                    conversationId: conversationId,
                    conversationManager: conversationManager
                )
                await viewModel?.loadReports()
            }
        }
        .refreshable {
            await viewModel?.refresh()
        }
        .sheet(item: $selectedReport) { identifiableReport in
            ReportResolutionSheet(
                report: identifiableReport.report,
                viewModel: viewModel!,
                onDismiss: {
                    selectedReport = nil
                }
            )
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
            Text("Reports are only available to conversation admins.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Reports List

    @ViewBuilder
    private func reportsList(viewModel: MLSReportsViewModel) -> some View {
        List {
            // Pending reports section
            if !viewModel.pendingReports.isEmpty {
                Section {
                    ForEach(viewModel.pendingReports, id: \.id) { report in
                        ReportRow(report: report, viewModel: viewModel)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedReport = IdentifiableReport(report)
                            }
                            .glassEffect()
                    }
                } header: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Pending Reports")
                        Spacer()
                        Text("\(viewModel.pendingReports.count)")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.2))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
            } else if !viewModel.isLoadingReports {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(.green)
                            Text("No Pending Reports")
                                .font(.headline)
                            Text("All reports have been reviewed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 32)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }

            // Resolved reports section
            if !viewModel.resolvedReports.isEmpty {
                Section {
                    ForEach(viewModel.resolvedReports, id: \.id) { report in
                        ReportRow(report: report, viewModel: viewModel, isResolved: true)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedReport = IdentifiableReport(report)
                            }
                            .glassEffect()
                    }

                    if viewModel.hasMoreReports {
                        HStack {
                            Spacer()
                            Button {
                                Task {
                                    await viewModel.loadMoreReports()
                                }
                            } label: {
                                if viewModel.isLoadingReports {
                                    ProgressView()
                                } else {
                                    Text("Load More")
                                }
                            }
                            .buttonStyle(.borderless)
                            Spacer()
                        }
                    }
                } header: {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Resolved Reports")
                        Spacer()
                        Text("\(viewModel.resolvedReports.count)")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.green.opacity(0.2))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }
            }

            // Loading indicator
            if viewModel.isLoadingReports && viewModel.allReports.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
    }
}

// MARK: - Report Row

@available(iOS 26.0, *)
private struct ReportRow: View {
    let report: BlueCatbirdMlsGetReports.ReportView
    let viewModel: MLSReportsViewModel
    var isResolved: Bool = false

    @State private var decryptedContent: String?
    @State private var isDecrypting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with reporter and reported member
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Reporter:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(viewModel.getDisplayName(for: report.reporterDid))
                            .font(.caption)
                            .fontWeight(.medium)
                    }

                    HStack(spacing: 4) {
                        Text("Reported:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(viewModel.getDisplayName(for: report.reportedDid))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(viewModel.getRelativeTime(for: report.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if isResolved {
                        if let resolvedBy = report.resolvedBy {
                            Text("By: \(viewModel.getDisplayName(for: resolvedBy))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Status badge
            HStack {
                Image(systemName: isResolved ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption)
                Text(report.status.capitalized)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isResolved ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
            .foregroundStyle(isResolved ? .green : .orange)
            .clipShape(Capsule())

            // Content preview section
            if let content = decryptedContent {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Report Details:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    Text(content)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if isDecrypting {
                HStack {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Decrypting content...")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            } else {
                Button {
                    Task {
                        isDecrypting = true
                        decryptedContent = await viewModel.decryptReportContent(report: report)
                        isDecrypting = false
                    }
                } label: {
                    HStack {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                        Text("Tap to decrypt content")
                            .font(.caption2)
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Report Resolution Sheet

@available(iOS 26.0, *)
private struct ReportResolutionSheet: View {
    let report: BlueCatbirdMlsGetReports.ReportView
    let viewModel: MLSReportsViewModel
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedAction: MLSReportsViewModel.ResolutionAction?
    @State private var resolutionNotes = ""
    @State private var isProcessing = false
    @State private var showingConfirmation = false
    @State private var showingError = false
    @State private var errorMessage: String?
    @State private var decryptedContent: String?
    @State private var isDecrypting = false

    private let logger = Logger(subsystem: "blue.catbird", category: "ReportResolution")

    private let notesCharacterLimit = 500

    var body: some View {
        NavigationStack {
            Form {
                // Report info section
                Section("Report Details") {
                    LabeledContent("Reporter", value: viewModel.getDisplayName(for: report.reporterDid))
                    LabeledContent("Reported", value: viewModel.getDisplayName(for: report.reportedDid))
                    LabeledContent("Created", value: viewModel.getAbsoluteDate(for: report.createdAt))
                    LabeledContent("Status", value: report.status.capitalized)
                }

                // Decrypted content section
                Section("Report Content") {
                    if let content = decryptedContent {
                        Text(content)
                            .font(.body)
                            .textSelection(.enabled)
                    } else if isDecrypting {
                        HStack {
                            ProgressView()
                            Text("Decrypting...")
                        }
                    } else {
                        Button("Decrypt Content") {
                            Task {
                                isDecrypting = true
                                decryptedContent = await viewModel.decryptReportContent(report: report)
                                isDecrypting = false
                            }
                        }
                    }
                }

                // Action selection (only for pending reports)
                if report.status == "pending" {
                    Section("Resolution Action") {
                        ForEach(MLSReportsViewModel.ResolutionAction.allCases, id: \.self) { action in
                            Button {
                                selectedAction = action
                            } label: {
                                HStack {
                                    Image(systemName: action.icon)
                                        .frame(width: 24)
                                        .foregroundStyle(selectedAction == action ? .blue : .secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(action.title)
                                            .foregroundStyle(.primary)
                                        Text(action.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if selectedAction == action {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .glassEffect()
                        }
                    }

                    // Resolution notes
                    Section {
                        ZStack(alignment: .topLeading) {
                            if resolutionNotes.isEmpty {
                                Text("Add notes about this resolution (optional but recommended)")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                            }

                            TextEditor(text: $resolutionNotes)
                                .frame(minHeight: 100)
                                .onChange(of: resolutionNotes) { _, newValue in
                                    if newValue.count > notesCharacterLimit {
                                        resolutionNotes = String(newValue.prefix(notesCharacterLimit))
                                    }
                                }
                        }

                        HStack {
                            Spacer()
                            Text("\(resolutionNotes.count)/\(notesCharacterLimit)")
                                .font(.caption)
                                .foregroundStyle(resolutionNotes.count >= notesCharacterLimit ? .red : .secondary)
                        }
                    } header: {
                        Text("Resolution Notes")
                    }
                } else {
                    // Show resolution details for resolved reports
                    Section("Resolution") {
                        if let resolvedBy = report.resolvedBy {
                            LabeledContent("Resolved By", value: viewModel.getDisplayName(for: resolvedBy))
                        }
                        if let resolvedAt = report.resolvedAt {
                            LabeledContent("Resolved At", value: viewModel.getAbsoluteDate(for: resolvedAt))
                        }
                    }
                }
            }
            .navigationTitle(report.status == "pending" ? "Resolve Report" : "Report Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onDismiss()
                        dismiss()
                    }
                    .disabled(isProcessing)
                }

                if report.status == "pending" {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Resolve") {
                            showingConfirmation = true
                        }
                        .disabled(selectedAction == nil || isProcessing)
                        .fontWeight(.semibold)
                    }
                }
            }
            .disabled(isProcessing)
            .overlay {
                if isProcessing {
                    LoadingOverlay()
                }
            }
            .confirmationDialog(
                selectedAction?.title ?? "",
                isPresented: $showingConfirmation,
                presenting: selectedAction
            ) { action in
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    Task {
                        await resolveReport()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { action in
                Text("Are you sure you want to \(action.title.lowercased())? This action cannot be undone.")
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                }
            }
        }
    }

    @MainActor
    private func resolveReport() async {
        guard let action = selectedAction else { return }

        isProcessing = true
        defer { isProcessing = false }

        do {
            try await viewModel.resolveReport(
                report,
                action: action,
                notes: resolutionNotes.isEmpty ? nil : resolutionNotes
            )

            logger.info("Successfully resolved report: \(self.report.id)")
            onDismiss()
            dismiss()
        } catch {
            logger.error("Failed to resolve report: \(error.localizedDescription)")
            errorMessage = "Failed to resolve report. Please try again."
            showingError = true
        }
    }
}

// MARK: - Loading Overlay

@available(iOS 26.0, *)
private struct LoadingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .tint(.white)
                Text("Processing...")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(Color.black.opacity(0.7))
            .glassEffect()
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

#endif
