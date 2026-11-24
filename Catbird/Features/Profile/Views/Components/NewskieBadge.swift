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
    public static func formattedJoinDate(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale))
    }
    
    /// Generates dialog description text for the account.
    public static func dialogMessage(
        handle: String,
        isSelf: Bool,
        createdAt: Date?,
        hasStarterPack: Bool,
        locale: Locale = .current
    ) -> String {
        if let createdAt {
            let dateString = formattedJoinDate(createdAt, locale: locale)
            if isSelf {
                if hasStarterPack {
                    return String(
                        localized: "You joined Bluesky on \(dateString) using a starter pack.",
                        locale: locale,
                        comment: "New user dialog message for the signed-in user who joined via a starter pack — %1$@ is the formatted join date."
                    )
                } else {
                    return String(
                        localized: "You joined Bluesky on \(dateString). Welcome!",
                        locale: locale,
                        comment: "New user dialog message for the signed-in user — %1$@ is the formatted join date."
                    )
                }
            } else {
                if hasStarterPack {
                    return String(
                        localized: "@\(handle) joined Bluesky on \(dateString) using a starter pack.",
                        locale: locale,
                        comment: "New user dialog message for another account that joined via a starter pack — %1$@ is the user's handle (without @), %2$@ is the formatted join date."
                    )
                } else {
                    return String(
                        localized: "@\(handle) joined Bluesky on \(dateString).",
                        locale: locale,
                        comment: "New user dialog message for another account — %1$@ is the user's handle (without @), %2$@ is the formatted join date."
                    )
                }
            }
        } else {
            if isSelf {
                if hasStarterPack {
                    return String(
                        localized: "You joined Bluesky recently using a starter pack.",
                        locale: locale,
                        comment: "New user dialog message for the signed-in user who joined via a starter pack when join date is unknown."
                    )
                } else {
                    return String(
                        localized: "You joined Bluesky recently. Welcome!",
                        locale: locale,
                        comment: "New user dialog message for the signed-in user when join date is unknown."
                    )
                }
            } else {
                if hasStarterPack {
                    return String(
                        localized: "@\(handle) joined Bluesky recently using a starter pack.",
                        locale: locale,
                        comment: "New user dialog message for another account that joined via a starter pack when join date is unknown — %1$@ is the user's handle (without @)."
                    )
                } else {
                    return String(
                        localized: "@\(handle) joined Bluesky recently.",
                        locale: locale,
                        comment: "New user dialog message for another account when join date is unknown — %1$@ is the user's handle (without @)."
                    )
                }
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
                    
                    Text("New", comment: "Short badge label shown beside the handle of a newly created account.")
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
    @Environment(\.locale) private var locale
    
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
                Text("New User", comment: "Heading in the new-account info sheet.")
                    .appFont(AppTextRole.title2)
                    .fontWeight(.bold)
                
                // Message
                Text(
                    NewskieHelper.dialogMessage(
                        handle: profile.handle.description,
                        isSelf: isSelf,
                        createdAt: profile.createdAt?.date,
                        hasStarterPack: profile.joinedViaStarterPack != nil,
                        locale: locale
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
