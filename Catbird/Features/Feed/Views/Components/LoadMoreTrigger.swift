//
//  LoadMoreTrigger.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/25/25.
//

import SwiftUI

/// An invisible view that triggers loading more posts when it comes into view.
/// Uses modern Swift concurrency patterns with @Sendable functions.
struct LoadMoreTrigger: View {
    // MARK: - Properties
    
    /// The action to execute when loading more content
    let loadMoreAction: @Sendable () async -> Void
    
    /// Track if this trigger has already been activated
    @State private var isTriggered = false
    
    /// Base spacing unit (multiple of 3pt)
    private static let baseUnit: CGFloat = 3
    
    // MARK: - Body
    var body: some View {
        Color.clear
            .frame(height: LoadMoreTrigger.baseUnit)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .onAppear {
                // Only trigger once to avoid repeated calls
                guard !isTriggered else { return }
                
                // Mark as triggered immediately to prevent double-loading
                isTriggered = true
                
                // Execute the load more action with proper task isolation
                Task { @MainActor in
                    #if DEBUG
                    print("LoadMoreTrigger: Loading more posts...")
                    #endif
                    
                    // Use a task detached with proper priority
                    Task.detached(priority: .userInitiated) { @Sendable in
                        await loadMoreAction()
                    }
                }
            }
    }
}

#Preview {
    // Preview with a simple loading action
    LoadMoreTrigger {
        try? await Task.sleep(for: .seconds(2))
        print("More content loaded")
    }
    .frame(width: 300, height: 50)
    .border(.gray)
}
