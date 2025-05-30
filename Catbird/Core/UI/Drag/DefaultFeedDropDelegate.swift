//
//  DefaultFeedDropDelegate.swift
//  Catbird
//
//  Created by Josh LaCalamito on 4/28/25.
//

import SwiftUI
import Petrel

struct DefaultFeedDropDelegate: DropDelegate {
  let viewModel: FeedsStartPageViewModel
  @Binding var draggedItem: String?
  @Binding var isDragging: Bool
  @Binding var draggedItemCategory: String?
  @Binding var dropTargetItem: String?
  @Binding var selectedFeed: FetchType
  @Binding var currentFeedName: String
  @Binding var isDefaultFeedDropTarget: Bool
  @Binding var defaultFeed: String?
  @Binding var defaultFeedName: String
  let resetDragState: () -> Void

  let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)

  func dropEntered(info: DropInfo) {
    if draggedItem != nil {
      withAnimation(.spring(duration: 0.3)) {
        isDefaultFeedDropTarget = true
        dropTargetItem = "default-feed-button"
      }
      feedbackGenerator.impactOccurred(intensity: 0.7)
    }
  }

  func dropExited(info: DropInfo) {
    if dropTargetItem == "default-feed-button" {
      withAnimation(.spring(duration: 0.3)) {
        isDefaultFeedDropTarget = false
        dropTargetItem = nil
      }
    }
  }

  func performDrop(info: DropInfo) -> Bool {
    guard let draggedFeedURI = draggedItem else {
      resetDragState()
      return false
    }

    let feedToSet = draggedFeedURI
    resetDragState()
    feedbackGenerator.impactOccurred(intensity: 1.0)

    // Set the dragged feed as the default (first pinned feed)
    Task {
      await viewModel.setDefaultFeed(feedToSet)
      
      // Update the UI immediately for better responsiveness
      if SystemFeedTypes.isTimelineFeed(feedToSet) {
        defaultFeed = feedToSet
        defaultFeedName = "Timeline"
        selectedFeed = .timeline
        currentFeedName = "Timeline"
      } else if let uri = try? ATProtocolURI(uriString: feedToSet) {
        defaultFeed = feedToSet
        defaultFeedName = viewModel.feedGenerators[uri]?.displayName ?? viewModel.extractTitle(from: uri)
        selectedFeed = .feed(uri)
        currentFeedName = defaultFeedName
      }
      
      await viewModel.updateCaches()
    }

    return true
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    return DropProposal(operation: .move)
  }

  func validateDrop(info: DropInfo) -> Bool {
    return draggedItem != nil
  }
}
