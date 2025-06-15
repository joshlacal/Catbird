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
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(moreTabs, id: \.self) { tab in
                    Button {
                        // Push the new view onto the navigation stack
                        path.append(ProfileNavigationDestination.section(tab))
                    } label: {
                        HStack(spacing: 16) {
                            // Tab icon
                            Image(systemName: tab.systemImage)
                                .appFont(AppTextRole.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                            
                            // Tab info
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title)
                                    .appFont(AppTextRole.headline)
                                    .foregroundStyle(.primary)
                                
                                Text(tab.subtitle)
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            // Chevron
                            Image(systemName: "chevron.right")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(Color(.secondarySystemBackground))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    if tab != moreTabs.last {
                        Divider()
                            .padding(.leading, 60)
                    }
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
            Spacer(minLength: 300)
        }
        .background(Color(.secondarySystemGroupedBackground))
    }
}
