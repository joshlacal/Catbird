//
//  AppNavigationManager.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/18/25.
//

import Observation
import SwiftUI

@Observable class AppNavigationManager {
    // One path per tab
    var tabPaths: [Int: NavigationPath] = [
        0: NavigationPath(),
        1: NavigationPath(),
        2: NavigationPath(),
        3: NavigationPath(),
        4: NavigationPath() // Add path for Chat tab
    ]
    
    // Track the current tab index
    private(set) var currentTabIndex: Int = 0
    var tabSelection: ((Int) -> Void)?
    
    // Target conversation for deep-link navigation (Chat tab specific)
    var targetConversationId: String?

    // Set the current tab index - called when the user switches tabs
    func updateCurrentTab(_ index: Int) {
        currentTabIndex = index
    }

    // Add a method to register the tab selection callback
    func registerTabSelectionCallback(_ callback: @escaping (Int) -> Void) {
        self.tabSelection = callback
    }
    
    // Navigate to a destination in the current tab or a specified tab
    func navigate(to destination: NavigationDestination, in tabIndex: Int? = nil) {
        // Always use the current tab unless explicitly specified
        let targetTab = tabIndex ?? currentTabIndex
        
        #if os(iOS)
        // Special handling for conversation navigation in chat tab
        if case .conversation(let convoId) = destination, targetTab == 4 {
            // For chat tab, set the target conversation ID instead of using navigation path
            // This properly handles the NavigationSplitView architecture
            targetConversationId = convoId
            // Clear the navigation path to ensure clean navigation state
            tabPaths[targetTab] = NavigationPath()
            return
        }
        #endif
        
        tabPaths[targetTab]?.append(destination)
    }
    
    // Clear the navigation path for a tab
    func clearPath(for tabIndex: Int) {
        tabPaths[tabIndex] = NavigationPath()
    }
    
    // Check if a tab has any navigation path items
    func hasItems(in tabIndex: Int) -> Bool {
        return (tabPaths[tabIndex]?.count ?? 0) > 0
    }
    
    // Get a binding to the navigation path for a tab
    func pathBinding(for tabIndex: Int) -> Binding<NavigationPath> {
        Binding(
            get: { self.tabPaths[tabIndex] ?? NavigationPath() },
            set: { self.tabPaths[tabIndex] = $0 }
        )
    }
    
}
