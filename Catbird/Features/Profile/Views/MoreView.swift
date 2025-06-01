//
//  MoreView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 4/3/25.
//

import SwiftUI

// MARK: - More View
struct MoreView: View {
    @Binding var path: NavigationPath
    
    // Tabs to show in the More menu
    private let moreTabs = [ProfileTab.likes, ProfileTab.lists, ProfileTab.starterPacks, ProfileTab.feeds]
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(moreTabs, id: \.self) { tab in
                Button {
                    // Push the new view onto the navigation stack
                    path.append(ProfileNavigationDestination.section(tab))
                } label: {
                    HStack {
                        Text(tab.title)
                            .appFont(AppTextRole.headline)
                            .padding(.vertical, 16)
                            .foregroundStyle(.primary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if tab != moreTabs.last {
                    Divider()
                        .padding(.horizontal)
                }
            }
        }
        .background(Color(.systemBackground))
    }
}
