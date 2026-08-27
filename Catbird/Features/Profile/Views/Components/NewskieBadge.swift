//
//  NewskieBadge.swift
//  Catbird
//
//  Created for Bluesky social app parity (WS-H / G61).
//

import SwiftUI
import Petrel

/// Helper logic for determining Newskie status and copy.
public enum NewskieHelper {
    public static let newskieDuration: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    
    /// Returns whether the given creation date qualifies as a "Newskie" (<= 7 days old).
    public static func isNewskie(createdAt: Date?, referenceDate: Date = Date()) -> Bool {
        guard let createdAt = createdAt else { return false }
        let interval = referenceDate.timeIntervalSince(createdAt)
        return interval >= 0 && interval <= newskieDuration
    }
    
    /// Formats the join date string for display in the Newskie dialog.
    public static func formattedJoinDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    
    /// Generates dialog description text for the account.
    public static func dialogMessage(
        handle: String,
        isSelf: Bool,
        createdAt: Date?,
        hasStarterPack: Bool
    ) -> String {
        let dateString = createdAt.map { formattedJoinDate($0) } ?? "recently"
        
        if isSelf {
            if hasStarterPack {
                return "You joined Bluesky on \(dateString) using a starter pack."
            } else {
                return "You joined Bluesky on \(dateString). Welcome!"
            }
        } else {
            if hasStarterPack {
                return "@\(handle) joined Bluesky on \(dateString) using a starter pack."
            } else {
                return "@\(handle) joined Bluesky on \(dateString)."
            }
        }
    }
}

/// A badge displayed beside the handle of an account that joined within the last 7 days.
public struct NewskieBadge: View {
    let profile: AppBskyActorDefs.ProfileViewDetailed
    let isSelf: Bool
    @Binding var path: NavigationPath
    
    @State private var showingDialog: Bool = false
    
    public init(
        profile: AppBskyActorDefs.ProfileViewDetailed,
        isSelf: Bool,
        path: Binding<NavigationPath>
    ) {
        self.profile = profile
        self.isSelf = isSelf
        self._path = path
    }
    
    private var isEligible: Bool {
        guard let createdAtDate = profile.createdAt?.date else { return false }
        return NewskieHelper.isNewskie(createdAt: createdAtDate)
    }
    
    public var body: some View {
        if isEligible {
            Button {
                showingDialog = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.green)
                    
                    Text("New")
                        .appFont(AppTextRole.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.green.opacity(0.15))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New user")
            .accessibilityHint("Shows account join information")
            .sheet(isPresented: $showingDialog) {
                NewskieDialog(
                    profile: profile,
                    isSelf: isSelf,
                    path: $path
                )
            }
        }
    }
}

/// Informational dialog opened when tapping the Newskie badge.
public struct NewskieDialog: View {
    let profile: AppBskyActorDefs.ProfileViewDetailed
    let isSelf: Bool
    @Binding var path: NavigationPath
    
    @Environment(\.dismiss) private var dismiss
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Sprout Header Icon
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 72, height: 72)
                    
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                }
                .padding(.top, 24)
                
                // Title
                Text("New User")
                    .appFont(AppTextRole.title2)
                    .fontWeight(.bold)
                
                // Message
                Text(
                    NewskieHelper.dialogMessage(
                        handle: profile.handle.description,
                        isSelf: isSelf,
                        createdAt: profile.createdAt?.date,
                        hasStarterPack: profile.joinedViaStarterPack != nil
                    )
                )
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                
                // Starter Pack Card (if joined via starter pack)
                if let starterPack = profile.joinedViaStarterPack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Joined via Starter Pack")
                            .appFont(AppTextRole.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                        
                        Button {
                            dismiss()
                            path.append(NavigationDestination.starterPack(starterPack.uri))
                        } label: {
                            StarterPackRowView(pack: starterPack)
                                .padding(12)
                                .background(Color.systemGray6)
                                .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                }
                
                Spacer()
            }
            .navigationTitle("New User Info")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
