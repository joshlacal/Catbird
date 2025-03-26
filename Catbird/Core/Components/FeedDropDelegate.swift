import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct FeedDropDelegate: DropDelegate {
  // The feed URI this delegate is attached to
  let item: String
  
  // All items in this category (pinned or saved)
  let items: [String]
  
  // Category this delegate belongs to ("pinned" or "saved")
  let category: String
  
  // View model for feed management
  let viewModel: FeedsStartPageViewModel
  
  // Reference to the currently dragged item
  @Binding var draggedItem: String?
  
  // Whether a drag operation is in progress
  @Binding var isDragging: Bool
  
  // The category of the currently dragged item (for cross-category drops)
  @Binding var draggedItemCategory: String?
  
  // Reference to the drop target item for animations
  @Binding var dropTargetItem: String?
  
  // Haptic feedback generator
  let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
  
  // Called when a drag enters this drop area
  func dropEntered(info: DropInfo) {
    guard let _ = self.draggedItem, draggedItem != item else { return }
    
    // Set this item as the drop target to trigger animations
    withAnimation(.spring(duration: 0.3)) {
      dropTargetItem = item
    }
    
    // Provide haptic feedback when an item enters a valid drop area
    feedbackGenerator.impactOccurred(intensity: 0.7)
  }
  
  // Called when a drop is performed
  func performDrop(info: DropInfo) -> Bool {
    // Make sure we have a valid dragged item
    guard let currentDraggedItem = draggedItem,
          let currentDraggedCategory = draggedItemCategory else {
      clearDragState()
      return false
    }
    
    // Save the values before resetting the state
    let fromItem = currentDraggedItem
    let toItem = item
    let fromCategory = currentDraggedCategory
    let toCategory = category
    
    // Reset the drag state IMMEDIATELY
    clearDragState()
    
    // Strong haptic feedback for successful drop
    feedbackGenerator.impactOccurred(intensity: 1.0)
    
    // Process the drop
    Task {
      if fromCategory == toCategory {
        // If same category, handle as reorder
        if fromCategory == "pinned" {
          await viewModel.reorderPinnedFeed(from: fromItem, to: toItem)
        } else {
          await viewModel.reorderSavedFeed(from: fromItem, to: toItem)
        }
      } else {
        // If different category, handle as pin/unpin
        await viewModel.togglePinStatus(for: fromItem)
      }
      
      await viewModel.updateCaches()
    }
    
    return true
  }
  
  func dropExited(info: DropInfo) {
    // Clear this item as drop target if it was set
    if dropTargetItem == item {
      withAnimation(.spring(duration: 0.3)) {
        dropTargetItem = nil
      }
    }
  }
  
  func dropUpdated(info: DropInfo) -> DropProposal? {
    return DropProposal(operation: .move)
  }
  
  func validateDrop(info: DropInfo) -> Bool {
    // Allow drops of different items from any category
    return draggedItem != nil && draggedItem != item
  }
  
  private func clearDragState() {
    // Immediately clear all state variables
    DispatchQueue.main.async {
      self.draggedItem = nil
      self.isDragging = false
      self.draggedItemCategory = nil
      self.dropTargetItem = nil
    }
  }
}
