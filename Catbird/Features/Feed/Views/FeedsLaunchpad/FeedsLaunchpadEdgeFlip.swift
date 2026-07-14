//
//  FeedsLaunchpadEdgeFlip.swift
//  Catbird
//
//  Launchpad-style drag paging: hovering a dragged feed over the drawer's
//  top/bottom edge flips pages after a dwell, repeating while held. Also the
//  page-background drop target (drop on empty space appends to the page's
//  section).
//

#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class FeedsLaunchpadEdgeFlipCoordinator {
  private var dwellTask: Task<Void, Never>?

  func begin(interval: Duration = .milliseconds(400), flip: @escaping @MainActor () -> Void) {
    cancel()
    dwellTask = Task { @MainActor in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: interval)
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        flip()
      }
    }
  }

  func cancel() {
    dwellTask?.cancel()
    dwellTask = nil
  }

  deinit {
    dwellTask?.cancel()
  }
}

@MainActor
struct FeedsLaunchpadEdgeFlipDelegate: DropDelegate {
  let coordinator: FeedsLaunchpadEdgeFlipCoordinator
  let flip: @MainActor () -> Void
  let resetDragState: () -> Void

  func validateDrop(info: DropInfo) -> Bool { true }

  func dropEntered(info: DropInfo) {
    coordinator.begin(flip: flip)
  }

  func dropExited(info: DropInfo) {
    coordinator.cancel()
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    // Releasing on the edge strip is not a drop; clean up and let the drag
    // system reset.
    coordinator.cancel()
    resetDragState()
    return false
  }
}

/// Drop on a page's empty space: cross-section drags toggle pin status;
/// same-section drags move the feed to the end of the section.
@MainActor
struct FeedsLaunchpadPageDropDelegate: DropDelegate {
  let section: FeedsLaunchpadSection
  let viewModel: FeedsStartPageViewModel
  @Binding var draggedItem: String?
  @Binding var draggedItemCategory: String?
  let resetDragState: () -> Void

  func validateDrop(info: DropInfo) -> Bool {
    draggedItem != nil
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    defer { resetDragState() }
    guard let dragged = draggedItem, let fromCategory = draggedItemCategory else {
      return false
    }

    PlatformHaptics.customImpact(intensity: 1.0)

    let targetSection = section
    Task {
      if fromCategory != targetSection.rawValue {
        await viewModel.togglePinStatus(for: dragged)
      } else {
        let items = targetSection == .pinned
          ? viewModel.cachedPinnedFeeds
          : viewModel.cachedSavedFeeds
        if let last = items.last, last != dragged {
          if targetSection == .pinned {
            await viewModel.reorderPinnedFeed(from: dragged, to: last)
          } else {
            await viewModel.reorderSavedFeed(from: dragged, to: last)
          }
        }
      }
    }
    return true
  }
}
#endif
