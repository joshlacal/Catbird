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
        3: NavigationPath()
    ]
    
    // Track the current tab index
    private(set) var currentTabIndex: Int = 0
    
    // Set the current tab index - called when the user switches tabs
    func updateCurrentTab(_ index: Int) {
        currentTabIndex = index
    }
    
    // Navigate to a destination in the current tab or a specified tab
    func navigate(to destination: NavigationDestination, in tabIndex: Int? = nil) {
        // Always use the current tab unless explicitly specified
        let targetTab = tabIndex ?? currentTabIndex
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

