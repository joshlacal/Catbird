//
//  MoreView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 4/3/25.
//

import SwiftUI

// MARK: - More View
struct MoreView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Binding var path: NavigationPath
    
    // Tabs to show in the More menu
    private let moreTabs = [ProfileTab.likes, ProfileTab.lists, ProfileTab.starterPacks, ProfileTab.feeds]
    
    var body: some View {
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
                            .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))
                            .frame(width: 24, height: 24)
                        
                        // Tab info
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tab.title)
                                .appFont(AppTextRole.headline)
                                .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .primary, currentScheme: colorScheme))
                            
                            Text(tab.subtitle)
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))
                        }
                        
                        Spacer()
                        
                        // Chevron
                        Image(systemName: "chevron.right")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .tertiary, currentScheme: colorScheme))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .background(Color.elevatedBackground(appState.themeManager, elevation: .low, currentScheme: colorScheme))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                if tab != moreTabs.last {
                    Divider()
                        .background(Color.adaptiveSeparator(appState: appState, themeManager: appState.themeManager, currentScheme: colorScheme))
                        .padding(.leading, 60)
                }
            }
        }
        .background(Color.elevatedBackground(appState.themeManager, elevation: .low, currentScheme: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.adaptiveBorder(appState: appState, themeManager: appState.themeManager, isProminent: false, currentScheme: colorScheme), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.top, 16)

        Spacer(minLength: 100)
    }
}
