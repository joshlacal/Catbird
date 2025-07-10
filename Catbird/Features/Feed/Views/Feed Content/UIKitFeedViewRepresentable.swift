//
//  UIKitFeedViewRepresentable.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/4/25.
//

import SwiftUI

@available(iOS 18.0, *)
struct UIKitFeedViewRepresentable: UIViewRepresentable {
  let posts: [CachedFeedViewPost]
  let appState: AppState
  let fetchType: FetchType
  @Binding var path: NavigationPath
  let loadMoreAction: @Sendable () async -> Void
  let refreshAction: @Sendable () async -> Void
  let onScrollOffsetChanged: ((CGFloat) -> Void)?
  
  @Environment(\.modelContext) private var modelContext
  
  func makeUIView(context: Context) -> UICollectionView {
    // Create the feed controller to use its layout and configuration
    let feedController = FeedViewController(
      appState: appState,
      fetchType: fetchType,
      path: $path,
      modelContext: modelContext
    )
    
    // Get the collection view safely
    guard let collectionView = feedController.collectionView else {
      // Fallback: create a basic collection view if feedController's is nil
      let layout = FeedCompositionalLayout(sectionProvider: { _, _ in
        let itemSize = NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1.0),
          heightDimension: .estimated(200)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
        return NSCollectionLayoutSection(group: group)
      })
      return UICollectionView(frame: .zero, collectionViewLayout: layout)
    }
    
    // Set up the coordinator to bridge UIKit and SwiftUI
    let coordinator = context.coordinator
    coordinator.feedController = feedController
    
    // Set the scroll offset callback on the feed controller
    feedController.onScrollOffsetChanged = onScrollOffsetChanged
    
    // Keep the feed controller as the delegate (don't override with coordinator)
    // The feed controller will handle scroll events and call our callback
    
    // Ensure proper navigation bar integration for large title behavior
    collectionView.contentInsetAdjustmentBehavior = .automatic
    
    return collectionView
  }
  
  func updateUIView(_ uiView: UICollectionView, context: Context) {
    // Update the feed controller with new posts
    if let feedController = context.coordinator.feedController {
      Task { @MainActor in
        await feedController.loadPostsDirectly(posts)
      }
      
      // Update scroll offset callback on the feed controller
      feedController.onScrollOffsetChanged = onScrollOffsetChanged
    }
    
    // Update scroll offset callback on coordinator as backup
    context.coordinator.onScrollOffsetChanged = onScrollOffsetChanged
  }
  
  func makeCoordinator() -> Coordinator {
    Coordinator(
      feedController: nil,
      loadMoreAction: loadMoreAction,
      refreshAction: refreshAction,
      onScrollOffsetChanged: onScrollOffsetChanged
    )
  }
  
  // MARK: - Coordinator
  
  class Coordinator: NSObject, UICollectionViewDelegate {
    var feedController: FeedViewController?
    let loadMoreAction: @Sendable () async -> Void
    let refreshAction: @Sendable () async -> Void
    var onScrollOffsetChanged: ((CGFloat) -> Void)?
    
    init(
      feedController: FeedViewController?,
      loadMoreAction: @escaping @Sendable () async -> Void,
      refreshAction: @escaping @Sendable () async -> Void,
      onScrollOffsetChanged: ((CGFloat) -> Void)?
    ) {
      self.feedController = feedController
      self.loadMoreAction = loadMoreAction
      self.refreshAction = refreshAction
      self.onScrollOffsetChanged = onScrollOffsetChanged
    }
    
    // Delegate scroll events - SwiftUI NavigationStack will automatically detect these
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      onScrollOffsetChanged?(scrollView.contentOffset.y)
    }
    
    // Handle selection and other collection view events
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
      feedController?.collectionView(collectionView, didSelectItemAt: indexPath)
    }
  }
}
