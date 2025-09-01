//
//  LoadMoreTrigger.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/25/25.
//

import SwiftUI
import OSLog

/// An invisible view that triggers loading more posts when it comes into view.
/// Uses modern Swift concurrency patterns with @Sendable functions and optimized performance.
struct LoadMoreTrigger: View {
    // MARK: - Properties
    
    /// The action to execute when loading more content
    let loadMoreAction: @Sendable () async -> Void
    
    /// Track if this trigger has already been activated
    @State private var isTriggered = false
    
    /// Track loading state to prevent multiple simultaneous requests
    @State private var isLoading = false
    
    /// Debounce timer to prevent rapid-fire triggers
    @State private var debounceTask: Task<Void, Never>?
    
    /// Base spacing unit from centralized constants
    private static let baseUnit: CGFloat = FeedConstants.baseSpacingUnit
    
    /// Debounce delay to prevent multiple rapid triggers
    private static let debounceDelay: Duration = .nanoseconds(FeedConstants.triggerDebounceDelay)
    
    /// Logger for debugging load more operations
    private let logger = Logger(subsystem: "blue.catbird", category: "LoadMoreTrigger")
    
    // MARK: - Body
    var body: some View {
        Color.clear
            .frame(height: LoadMoreTrigger.baseUnit)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .onAppear {
                triggerLoadMore()
            }
            .onDisappear {
                // Cancel any pending debounce task if the view disappears
                debounceTask?.cancel()
                debounceTask = nil
            }
    }
    
    // MARK: - Private Methods
    
    /// Optimized trigger method with debouncing and loading state management
    private func triggerLoadMore() {
        // Only trigger if not already triggered and not currently loading
        guard !isTriggered && !isLoading else { return }
        
        // Mark as triggered immediately to prevent double-loading
        isTriggered = true
        
        // Cancel any existing debounce task
        debounceTask?.cancel()
        
        // Start new debounced task
        debounceTask = Task {
            // Wait for debounce delay
            try? await Task.sleep(for: LoadMoreTrigger.debounceDelay)
            
            // Check if task was cancelled
            guard !Task.isCancelled else { return }
            
            // Set loading state
            await MainActor.run {
                isLoading = true
            }
            
            #if DEBUG
            logger.debug("LoadMoreTrigger: Loading more posts...")
            #endif
            
            do {
                // Execute the load more action with proper error handling
                await loadMoreAction()
            } catch {
                #if DEBUG
                logger.error("LoadMoreTrigger: Failed to load more posts: \(error)")
                #endif
            }
            
            // Reset loading state
            await MainActor.run {
                isLoading = false
                // Reset triggered state to allow future triggers when scrolling
                // This enables infinite scroll to work properly
                isTriggered = false
            }
        }
    }
}

#Preview {
    // Preview with a simple loading action
    LoadMoreTrigger {
        try? await Task.sleep(for: .seconds(2))
        logger.debug("More content loaded")
    }
    .frame(width: 300, height: 50)
    .border(.gray)
}
