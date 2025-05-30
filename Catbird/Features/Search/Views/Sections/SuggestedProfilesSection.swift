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
    
    private let logger = Logger(subsystem: "blue.catbird", category: "SuggestedProfilesSection")
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Suggested Profiles")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    onRefresh()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal)
            
            if profiles.isEmpty {
                emptyStateView
            } else {
                profilesListView
            }
        }
    }
    
    private var emptyStateView: some View {
        HStack {
            Spacer()
            
            VStack(spacing: 6) {
                ProgressView()
                    .padding(.bottom, 4)
                
                Text("Finding profiles for you...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 12)
            
            Spacer()
        }
    }
    
    private var profilesListView: some View {
        VStack(spacing: 0) {
            ForEach(profiles, id: \.did) { profile in
                Button {
                    onSelect(profile)
                } label: {
                    
                    ProfileRowView(profile: profile)
                        .padding(12)
                        .applyListRowModifiers(id: profile.did.didString())
                    
//                    HStack(spacing: 12) {
//                        AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 44)
//                            .shadow(color: Color.black.opacity(0.1), radius: 1, y: 1)
//                        
//                        VStack(alignment: .leading, spacing: 2) {
//                            Text(profile.displayName ?? "@\(profile.handle)")
//                                .font(.headline)
//                                .foregroundColor(.primary)
//                                .lineLimit(1)
//                            
//                            Text("@\(profile.handle)")
//                                .font(.subheadline)
//                                .foregroundColor(.secondary)
//                                .lineLimit(1)
//                            
//                            if let description = profile.description, !description.isEmpty {
//                                Text(description)
//                                    .font(.caption)
//                                    .foregroundColor(.secondary)
//                                    .lineLimit(1)
//                                    .padding(.top, 2)
//                            }
//                        }
//                        
//                        Spacer()
//                        
//                        // Only show follow button if not already following
//                        if profile.viewer?.following == nil {
//                            EnhancedFollowButton(profile: profile)
//                        } else {
//                            Text("Following")
//                                .font(.caption)
//                                .fontWeight(.medium)
//                                .foregroundColor(.secondary)
//                                .padding(.vertical, 5)
//                                .padding(.horizontal, 12)
//                                .background(
//                                    Capsule()
//                                        .fill(Color.gray.opacity(0.2))
//                                )
//                        }
//                    }
//                    .padding(.vertical, 8)
//                    .padding(.horizontal)
//                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                if profile != profiles.last {
                    Divider()
                        .padding(.leading, 68)
                }
            }
        }
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
        .padding(.horizontal)
    }
}
