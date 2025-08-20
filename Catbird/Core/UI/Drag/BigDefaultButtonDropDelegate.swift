//
//  BigDefaultButtonDropDelegate.swift
//  Catbird
//
//  Created by Josh LaCalamito on 4/18/25.
//

import Petrel
import SwiftUI
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers

@MainActor
struct BigDefaultButtonDropDelegate: DropDelegate {
  let viewModel: FeedsStartPageViewModel
  @Binding var draggedItem: String?
  @Binding var isDragging: Bool
  @Binding var draggedItemCategory: String?
  @Binding var dropTargetItem: String?
  @Binding var selectedFeed: FetchType
  @Binding var currentFeedName: String
  @Binding var isTimelineDropTarget: Bool
  @Binding var firstPinnedFeed: String?
  @Binding var firstPinnedFeedName: String
  let resetDragState: () -> Void

  #if os(iOS)
  let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
  #endif

  func dropEntered(info: DropInfo) {
    // Only highlight if dragging a valid item
    if draggedItem != nil {
      withAnimation(.spring(duration: 0.3)) {
        isTimelineDropTarget = true
        dropTargetItem = "timeline-button"
      }
      #if os(iOS)
      feedbackGenerator.impactOccurred(intensity: 0.7)
      #endif
    }
  }

  func dropExited(info: DropInfo) {
    if dropTargetItem == "timeline-button" {
      withAnimation(.spring(duration: 0.3)) {
        isTimelineDropTarget = false
        dropTargetItem = nil
      }
    }
  }

  func performDrop(info: DropInfo) -> Bool {
    guard let draggedFeedURI = draggedItem else {
      resetDragState()
      return false
    }

    // Immediately reset the visual state
    let feedToSet = draggedFeedURI
    resetDragState()
    #if os(iOS)
    feedbackGenerator.impactOccurred(intensity: 1.0)
    #endif

    // Update the local state immediately for UI responsiveness
    if let uri = try? ATProtocolURI(uriString: feedToSet) {
      firstPinnedFeed = feedToSet
      firstPinnedFeedName =
        viewModel.feedGenerators[uri]?.displayName ?? viewModel.extractTitle(from: uri)

      // Also update the feed selection for navigation
      selectedFeed = .feed(uri)
      currentFeedName = firstPinnedFeedName
    }

    // Then persist the change
    Task {
      await viewModel.setDefaultFeed(feedToSet)
      await viewModel.updateCaches()
    }

    return true
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    guard draggedItem != nil else { return nil }
    return DropProposal(operation: .move)
  }

  func validateDrop(info: DropInfo) -> Bool {
    return draggedItem != nil
  }
}
