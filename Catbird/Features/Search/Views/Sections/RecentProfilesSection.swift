//
//  RecentProfilesSection.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel

/// Recently viewed profiles as one compact, horizontally scrolling row.
struct RecentProfilesSection: View {
    let profiles: [RecentProfileSearch]
    let onSelect: (RecentProfileSearch) -> Void
    let onClear: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var avatarSize: CGFloat { dynamicTypeSize.isAccessibilitySize ? 64 : 52 }
    private var itemWidth: CGFloat { dynamicTypeSize.isAccessibilitySize ? 96 : 68 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchHistoryHeader(title: "Recently Viewed", clearLabel: "Clear recently viewed profiles",
                                onClear: onClear)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(profiles.prefix(10)) { profile in
                        profileButton(profile)
                    }
                }
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .accessibilityIdentifier("search.history.profiles")
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func profileButton(_ profile: RecentProfileSearch) -> some View {
        let name = profile.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? "@\(profile.handle)"
        return Button {
            onSelect(profile)
        } label: {
            VStack(spacing: 6) {
                AsyncProfileImage(url: URL(string: profile.avatarURL ?? ""), size: avatarSize,
                                  did: profile.did.didString(), labels: profile.labels)
                // Two lines, top-aligned, so names keep their meaning without uneven rows.
                Text(name)
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(width: itemWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityHint("Opens profile")
        .accessibilityAddTraits(.isButton)
    }
}

/// Shared header for search history sections: a quiet title with a trailing Clear action.
struct SearchHistoryHeader: View {
    let title: LocalizedStringKey
    let clearLabel: LocalizedStringKey
    let onClear: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .appFont(AppTextRole.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            Button("Clear", action: onClear)
                .appFont(AppTextRole.subheadline)
                .buttonStyle(.borderless)
                .accessibilityLabel(clearLabel)
        }
        .padding(.horizontal, 16)
    }
}

/// Model representing a recently viewed profile
struct RecentProfileSearch: Identifiable, Codable, Equatable {
    let id: DID
    let did: DID
    let handle: Handle
    let displayName: String?
    let avatarURL: String?
    /// Moderation labels, so adult avatars stay hidden. Optional so entries saved before labels
    /// were stored still decode.
    let labels: [ComAtprotoLabelDefs.Label]?
    let timestamp: Date
    
    init(
        did: DID,
        handle: Handle,
        displayName: String?,
        avatarURL: String?,
        labels: [ComAtprotoLabelDefs.Label]?
    ) {
        self.id = did
        self.did = did
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.labels = labels
        self.timestamp = Date()
    }
    
    init(from profile: AppBskyActorDefs.ProfileView) {
        self.id = profile.did
        self.did = profile.did
        self.handle = profile.handle
        self.displayName = profile.displayName
        self.avatarURL = profile.avatar?.uriString()
        self.labels = profile.labels
        self.timestamp = Date()
    }
    
    static func == (lhs: RecentProfileSearch, rhs: RecentProfileSearch) -> Bool {
        return lhs.did == rhs.did
    }
}
