//
//  DefaultFeedDropDelegate.swift
//  Catbird
//
//  Created by Josh LaCalamito on 4/28/25.
//

import SwiftUI
import Petrel
#if os(iOS)
import UIKit
#endif

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

#if os(iOS)
  let feedbackGenerator = UIImpactFeedbackGenerator(style: .medium)
#endif

  func dropEntered(info: DropInfo) {
    if draggedItem != nil {
      withAnimation(.spring(duration: 0.3)) {
        isDefaultFeedDropTarget = true
        dropTargetItem = "default-feed-button"
      }
#if os(iOS)
      feedbackGenerator.impactOccurred(intensity: 0.7)
#endif
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
#if os(iOS)
    feedbackGenerator.impactOccurred(intensity: 1.0)
#endif

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
      
      // Cache update and state invalidation are handled by setDefaultFeed above
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
