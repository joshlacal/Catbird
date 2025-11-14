//
//  MLSMemberActionsSheet.swift
//  Catbird
//
//  MLS moderation action sheet for members
//

import SwiftUI
import Petrel
import OSLog

#if os(iOS)

struct MLSMemberActionsSheet: View {
    // MARK: - Dependencies

    let conversationId: String
    let member: BlueCatbirdMlsDefs.MemberView
    let currentUserDid: String
    let isCurrentUserAdmin: Bool
    let isCurrentUserCreator: Bool
    let conversationManager: MLSConversationManager

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var isProcessing = false
    @State private var showingConfirmation = false
    @State private var confirmationAction: MemberAction?
    @State private var showingReportSheet = false
    @State private var showingError = false
    @State private var errorMessage: String?

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSMemberActions")

    // MARK: - Action Types

    enum MemberAction {
        case remove
        case promote
        case demote
        case report

        var title: String {
            switch self {
            case .remove: return "Remove Member"
            case .promote: return "Promote to Admin"
            case .demote: return "Demote Admin"
            case .report: return "Report Member"
            }
        }

        var confirmationMessage: String {
            switch self {
            case .remove: return "Are you sure you want to remove this member from the conversation?"
            case .promote: return "This member will gain admin privileges including the ability to remove members and manage settings."
            case .demote: return "This member will lose admin privileges."
            case .report: return "Report this member for misconduct."
            }
        }

        var isDestructive: Bool {
            switch self {
            case .remove, .demote: return true
            case .promote, .report: return false
            }
        }
    }

    // MARK: - Computed Properties

    private var memberDisplayName: String {
        // Use DID string for now - in production, would resolve to handle/display name
        member.did.description
    }

    private var isSelf: Bool {
        member.did.description == currentUserDid
    }

    private var isCreator: Bool {
        // Check if this member is the conversation creator
        // Note: Creator info should come from conversation, but we'll check admin status
        // In production, conversation would have creator DID field
        false // Placeholder - needs creator info from conversation
    }

    private var canRemove: Bool {
        isCurrentUserAdmin && !isSelf && !isCreator
    }

    private var canPromote: Bool {
        isCurrentUserAdmin && !member.isAdmin && !isSelf
    }

    private var canDemote: Bool {
        isCurrentUserAdmin && member.isAdmin && !isSelf && !isCreator
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                // Member info section
                Section {
                    HStack(spacing: 16) {
                        // Placeholder avatar
                        Circle()
                            .fill(Color.blue.gradient)
                            .frame(width: 60, height: 60)
                            .overlay {
                                Text(String(memberDisplayName.prefix(1)))
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white)
                            }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(memberDisplayName)
                                    .font(.headline)

                                if member.isAdmin {
                                    Text("ADMIN")
                                        .font(.caption2)
                                        .fontWeight(.bold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.2))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                }

                                if isCreator {
                                    Image(systemName: "star.fill")
                                        .font(.caption)
                                        .foregroundStyle(.yellow)
                                }
                            }

                            Text("Joined \(member.joinedAt.formattedDate)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                // User actions (always visible)
                Section {
                    Button {
                        showingReportSheet = true
                    } label: {
                        Label("Report Member", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    .disabled(isSelf || isProcessing)
                }

                // Admin actions (conditionally visible)
                if isCurrentUserAdmin && (canRemove || canPromote || canDemote) {
                    Section("Admin Actions") {
                        if canPromote {
                            Button {
                                confirmationAction = .promote
                                showingConfirmation = true
                            } label: {
                                Label("Promote to Admin", systemImage: "arrow.up.circle")
                            }
                            .disabled(isProcessing)
                        }

                        if canDemote {
                            Button {
                                confirmationAction = .demote
                                showingConfirmation = true
                            } label: {
                                Label("Demote Admin", systemImage: "arrow.down.circle")
                                    .foregroundStyle(.orange)
                            }
                            .disabled(isProcessing)
                        }

                        if canRemove {
                            Button(role: .destructive) {
                                confirmationAction = .remove
                                showingConfirmation = true
                            } label: {
                                Label("Remove Member", systemImage: "person.fill.xmark")
                            }
                            .disabled(isProcessing)
                        }
                    }
                }
            }
            .navigationTitle("Member Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isProcessing)
                }
            }
            .disabled(isProcessing)
            .overlay {
                if isProcessing {
                    LoadingOverlay()
                }
            }
            .confirmationDialog(
                confirmationAction?.title ?? "",
                isPresented: $showingConfirmation,
                presenting: confirmationAction
            ) { action in
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    Task {
                        await performAction(action)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { action in
                Text(action.confirmationMessage)
            }
            .sheet(isPresented: $showingReportSheet) {
                MLSReportMemberSheet(
                    conversationId: conversationId,
                    memberDid: member.did.description,
                    memberDisplayName: memberDisplayName,
                    conversationManager: conversationManager
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
    }

    // MARK: - Actions

    @MainActor
    private func performAction(_ action: MemberAction) async {
        isProcessing = true
        defer { isProcessing = false }

        do {
            switch action {
            case .remove:
                try await conversationManager.removeMember(
                    from: conversationId,
                    memberDid: member.did.description,
                    reason: "Removed by admin"
                )
                logger.info("Successfully removed member: \(self.member.did.description)")
                dismiss()

            case .promote:
                try await conversationManager.promoteAdmin(
                    in: conversationId,
                    memberDid: member.did.description
                )
                logger.info("Successfully promoted member to admin: \(self.member.did.description)")
                dismiss()

            case .demote:
                try await conversationManager.demoteAdmin(
                    in: conversationId,
                    memberDid: member.did.description
                )
                logger.info("Successfully demoted admin: \(self.member.did.description)")
                dismiss()

            case .report:
                // Handled by report sheet
                break
            }
        } catch {
            logger.error("Action failed: \(error.localizedDescription)")
            errorMessage = "Failed to \(action.title.lowercased()). Please try again."
            showingError = true
        }
    }
}

// MARK: - Loading Overlay

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
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

// MARK: - Date Formatting Extension

private extension ATProtocolDate {
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: self.date)
    }
}

#endif
