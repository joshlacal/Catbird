//
//  SuggestedProfilesSheet.swift
//  Catbird
//
//  Sheet view for suggested profiles
//

import SwiftUI
import Petrel
import OSLog

/// A sheet displaying suggested profiles for the user to follow
struct SuggestedProfilesSheet: View {
    let profiles: [AppBskyActorDefs.ProfileView]
    let onSelect: (AppBskyActorDefs.ProfileView) -> Void
    let onRefresh: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    private let logger = Logger(subsystem: "blue.catbird", category: "SuggestedProfilesSheet")
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if profiles.isEmpty {
                        emptyStateView
                    } else {
                        profilesListView
                    }
                }
                .padding(.vertical, 16)
            }
            .background(Color.dynamicGroupedBackground(appState.themeManager, currentScheme: colorScheme))
            .navigationTitle("Find Friends")
            #if os(iOS)
            .toolbarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.thinMaterial)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            
            Text("Finding profiles for you...")
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme))
        .cornerRadius(12)
        .mainContentFrame()
        .padding(.horizontal, 16)
    }
    
    private var profilesListView: some View {
        VStack(spacing: 12) {
            ForEach(profiles, id: \.did) { profile in
                profileCard(profile: profile)
            }
        }
        .mainContentFrame()
        .padding(.horizontal, 16)
    }
    
    private func profileCard(profile: AppBskyActorDefs.ProfileView) -> some View {
        Button {
            onSelect(profile)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 56)
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(profile.displayName ?? profile.handle.description)
                            .appFont(AppTextRole.body.weight(.semibold))
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    
                    Text("@\(profile.handle)")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    if let description = profile.description, !description.isEmpty {
                        Text(description)
                            .appFont(AppTextRole.footnote)
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .tertiary, currentScheme: colorScheme))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.top, 2)
                    }
                    
                    HStack(spacing: 12) {
                        if let viewer = profile.viewer, let knownFollowers = viewer.knownFollowers, knownFollowers.count > 0 {
                            Label {
                                Text("\(knownFollowers.count) mutual")
                                    .appFont(AppTextRole.caption)
                            } icon: {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                        }
                        
                        if let createdAt = profile.createdAt {
                            Label {
                                Text("Joined \(formatJoinDate(createdAt))")
                                    .appFont(AppTextRole.caption)
                            } icon: {
                                Image(systemName: "calendar")
                                    .font(.system(size: 10))
                            }
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                        }
                    }
                    .padding(.top, 4)
                }
                
                Spacer()
                
                followButtonView(profile: profile)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme).opacity(0.3), lineWidth: 0.5)
            )
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func followButtonView(profile: AppBskyActorDefs.ProfileView) -> some View {
        if profile.viewer?.following == nil {
            Button {
                // Follow action
            } label: {
                Text("Follow")
                    .appFont(AppTextRole.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor)
                    )
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .medium))
                Text("Following")
                    .appFont(AppTextRole.footnote.weight(.medium))
            }
            .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme), lineWidth: 1)
            )
        }
    }
    
    private func formatJoinDate(_ date: ATProtocolDate) -> String {
        let now = Date()
        let joinDate = date.toDate
        let components = Calendar.current.dateComponents([.year, .month], from: joinDate, to: now)
        
        if let years = components.year, years > 0 {
            return "\(years)y ago"
        } else if let months = components.month, months > 0 {
            return "\(months)mo ago"
        } else {
            return "recently"
        }
    }
}
