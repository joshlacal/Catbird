//
//  RecentProfilesSection.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel

/// A section displaying recently viewed profiles with horizontal scrolling
struct RecentProfilesSection: View {
    let profiles: [RecentProfileSearch]
    let onSelect: (RecentProfileSearch) -> Void
    let onClear: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recently Viewed Profiles")
                    .font(.headline)
                
                Spacer()
                
                Button("Clear", action: onClear)
                    .font(.subheadline)
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(profiles.prefix(10)) { profile in
                        Button {
                            onSelect(profile)
                        } label: {
                            VStack(spacing: 4) {
                                // Profile image
                                AsyncProfileImage(
                                    url: URL(string: profile.avatarURL ?? ""),
                                    size: 56
                                )
                                .overlay(
                                    Circle()
                                        .stroke(Color.accentColor, lineWidth: 2)
                                        .opacity(0.3)
                                )
                                
                                // Display name or handle
                                Text(profile.displayName ?? "@\(profile.handle)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .frame(width: 70)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// Model representing a recently viewed profile
struct RecentProfileSearch: Identifiable, Codable, Equatable {
    let id: String
    let did: String
    let handle: String
    let displayName: String?
    let avatarURL: String?
    let timestamp: Date
    
    init(
        did: String,
        handle: String,
        displayName: String?,
        avatarURL: String?
    ) {
        self.id = did
        self.did = did
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.timestamp = Date()
    }
    
    init(from profile: AppBskyActorDefs.ProfileView) {
        self.id = profile.did
        self.did = profile.did
        self.handle = profile.handle
        self.displayName = profile.displayName
        self.avatarURL = profile.avatar?.uriString()
        self.timestamp = Date()
    }
    
    static func == (lhs: RecentProfileSearch, rhs: RecentProfileSearch) -> Bool {
        return lhs.did == rhs.did
    }
}


