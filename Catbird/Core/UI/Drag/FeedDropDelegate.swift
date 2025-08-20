import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

@MainActor
struct FeedDropDelegate: DropDelegate {
  let item: String
  let items: [String]
  let category: String
  let viewModel: FeedsStartPageViewModel
  @Binding var draggedItem: String?
  @Binding var isDragging: Bool
  @Binding var draggedItemCategory: String?
  @Binding var dropTargetItem: String?
  let resetDragState: () -> Void
  let appSettings: AppSettings

#if os(iOS)
  let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
#endif

  func dropEntered(info: DropInfo) {
    guard draggedItem != nil, draggedItem != item else { return }
    MotionManager.withSpringAnimation(for: appSettings, duration: 0.3) {
      dropTargetItem = item
    }
#if os(iOS)
    feedbackGenerator.impactOccurred(intensity: 0.7)
#endif
  }

  func performDrop(info: DropInfo) -> Bool {
    defer { MotionManager.withSpringAnimation(for: appSettings, duration: 0.3) { resetDragState() } }
    guard let currentDraggedItem = draggedItem,
          let currentDraggedCategory = draggedItemCategory
    else {
      return false
    }

    let fromItem = currentDraggedItem
    let toItem = item
    let fromCategory = currentDraggedCategory
    let toCategory = category

#if os(iOS)
    feedbackGenerator.impactOccurred(intensity: 1.0)
#endif

    // Then do the database operations async
    Task {
      if fromCategory == toCategory {
        if fromCategory == "pinned" {
          await viewModel.reorderPinnedFeed(from: fromItem, to: toItem)
        } else {
          await viewModel.reorderSavedFeed(from: fromItem, to: toItem)
        }
      } else {
        await viewModel.togglePinStatus(for: fromItem)
      }
      // Cache update and state invalidation are handled by the individual methods above
    }

    return true
  }

  func dropExited(info: DropInfo) {
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
    return draggedItem != nil && draggedItem != item
  }
}
