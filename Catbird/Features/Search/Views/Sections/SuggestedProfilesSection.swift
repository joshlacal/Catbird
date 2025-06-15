//
//  SuggestedProfilesSection.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel
import OSLog

/// A section displaying suggested profiles for the user to follow
struct SuggestedProfilesSection: View {
    let profiles: [AppBskyActorDefs.ProfileView]
    let onSelect: (AppBskyActorDefs.ProfileView) -> Void
    let onRefresh: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    private let logger = Logger(subsystem: "blue.catbird", category: "SuggestedProfilesSection")
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Suggested For You", systemImage: "person.2")
                    .appFont(.customSystemFont(size: 17, weight: .medium, width: 120, relativeTo: .headline))
                
                Spacer()
                
                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.accentColor)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(Color.accentColor.opacity(0.1))
                        )
                }
            }
            .padding(.horizontal, 16)
            
            if profiles.isEmpty {
                emptyStateView
            } else {
                profilesCardView
            }
        }
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
        .padding(.horizontal, 16)
    }
    
    private var profilesCardView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(profiles.prefix(6), id: \.did) { profile in
                    profileCard(profile: profile)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 20)
        }
    }
    
    private func profileCard(profile: AppBskyActorDefs.ProfileView) -> some View {
        Button {
            onSelect(profile)
        } label: {
            VStack(alignment: .center, spacing: 14) {
                AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 64)
                
                VStack(spacing: 8) {
                    Text(profile.displayName ?? "@\(profile.handle)")
                        .appFont(AppTextRole.subheadline.weight(.semibold))
                        .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    Text("@\(profile.handle)")
                        .appFont(AppTextRole.footnote)
                        .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    if let description = profile.description, !description.isEmpty {
                        Text(description)
                            .appFont(AppTextRole.caption)
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .tertiary, currentScheme: colorScheme))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }
                
                Spacer(minLength: 8)
                
                followButtonView(profile: profile)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 20)
            .frame(width: 160, height: 220)
            .background(Color.elevatedBackground(appState.themeManager, elevation: .low, currentScheme: colorScheme))
            .cornerRadius(16)
            .shadow(color: Color.dynamicShadow(appState.themeManager, currentScheme: colorScheme), radius: 8, y: 4)
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
                    .appFont(AppTextRole.footnote.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor)
                    )
            }
        } else {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .appFont(AppTextRole.caption2)
                Text("Following")
                    .appFont(AppTextRole.footnote.weight(.medium))
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 1)
                    .fill(Color.accentColor.opacity(0.08))
            )
        }
    }
    
    private func formatFollowerCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let formatted = Double(count) / 1_000_000.0
            return String(format: "%.1fM", formatted)
        } else if count >= 1_000 {
            let formatted = Double(count) / 1_000.0
            return String(format: "%.1fK", formatted)
        } else {
            return "\(count)"
        }
    }
}
