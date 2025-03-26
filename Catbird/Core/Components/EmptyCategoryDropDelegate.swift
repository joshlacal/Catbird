import SwiftUI
import UniformTypeIdentifiers

/// Drop delegate for empty feed categories (allows dropping a feed on an empty category section)
@MainActor
struct EmptyCategoryDropDelegate: DropDelegate {
    // Category this delegate represents ("pinned" or "saved")
    let category: String
    
    // View model for feed management
    let viewModel: FeedsStartPageViewModel
    
    // Binding to the currently dragged item
    @Binding var draggedItem: String?
    
    // Binding for drag operation status
    @Binding var isDragging: Bool
    
    // The category of the currently dragged item
    @Binding var draggedItemCategory: String?
    
    // Reference to the drop target for animations
    @Binding var dropTargetItem: String?
    
    // Haptic feedback generator
    let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
    
    // Called when a drag enters the drop area
    func dropEntered(info: DropInfo) {
        // Set special target value for empty section
        withAnimation(.spring(duration: 0.3)) {
            dropTargetItem = "empty-" + category
        }
        feedbackGenerator.impactOccurred(intensity: 0.7)
    }
    
    // Called when a drag exits the drop area
    func dropExited(info: DropInfo) {
        // Clear target if it was set to our special value
        if dropTargetItem == "empty-" + category {
            withAnimation(.spring(duration: 0.3)) {
                dropTargetItem = nil
            }
        }
    }
    
    // Called when a drop is performed
    func performDrop(info: DropInfo) -> Bool {
        // Make sure we have a valid dragged item
        guard let currentDraggedItem = draggedItem,
              let currentDraggedCategory = draggedItemCategory,
              currentDraggedCategory != category else {
            clearDragState()
            return false
        }
        
        // Save the item before resetting the state
        let item = currentDraggedItem
        
        // Reset drag state immediately
        clearDragState()
        
        // Strong haptic feedback for successful drop
        feedbackGenerator.impactOccurred(intensity: 1.0)
        
        // Process the drop - toggle pin status
        Task {
            await viewModel.togglePinStatus(for: item)
            await viewModel.updateCaches()
        }
        
        return true
    }
    
    // Provide drop proposal
    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
    
    // Validate the drop operation
    func validateDrop(info: DropInfo) -> Bool {
        // Only allow drops from the other category
        return draggedItem != nil && draggedItemCategory != nil && draggedItemCategory != category
    }
    
    // Clear the drag state
    private func clearDragState() {
        DispatchQueue.main.async {
            self.draggedItem = nil
            self.isDragging = false
            self.draggedItemCategory = nil
            self.dropTargetItem = nil
        }
    }
}
