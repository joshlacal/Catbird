//
//  FullUIKitFeedWrapper.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/4/25.
//

import SwiftUI
import UIKit
import SwiftData

// MARK: - Legacy UIKit Feed Wrapper (keeping for compatibility)

/// A complete UIKit implementation that provides native navigation bar behavior
struct FullUIKitFeedWrapper: UIViewControllerRepresentable {
  let posts: [CachedFeedViewPost]
  let appState: AppState
  let fetchType: FetchType
  @Binding var path: NavigationPath
  let onScrollOffsetChanged: ((CGFloat) -> Void)?
@Environment(\.modelContext) private var modelContext
    
  func makeUIViewController(context: Context) -> UIKitFeedWrapperController {
    let controller = UIKitFeedWrapperController(
        appState: appState, fetchType: fetchType, path: $path, modelContext: modelContext)
    controller.feedController.onScrollOffsetChanged = onScrollOffsetChanged
    return controller
  }

  func updateUIViewController(_ uiViewController: UIKitFeedWrapperController, context: Context) {
    // Update scroll offset callback
    uiViewController.feedController.onScrollOffsetChanged = onScrollOffsetChanged
    
    // Update posts (with built-in change detection in loadPostsDirectly)
    Task { @MainActor in
      await uiViewController.feedController.loadPostsDirectly(posts)
    }
    
    // Handle fetch type changes
    if uiViewController.feedController.fetchType.identifier != fetchType.identifier {
      uiViewController.feedController.handleFetchTypeChange(to: fetchType)
    }

    // Handle tab tap to scroll to top
    if let tapped = appState.tabTappedAgain, tapped == 0 {
      uiViewController.feedController.scrollToTop()

      // Reset the tabTappedAgain value after handling
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        appState.tabTappedAgain = nil
      }
    }
  }
}

// MARK: - UIKit Feed Wrapper Controller

/// A UIKit view controller that properly integrates with navigation hierarchy
@available(iOS 18.0, *)
final class UIKitFeedWrapperController: UIViewController {
  let feedController: FeedViewController
  private let appState: AppState

  init(appState: AppState, fetchType: FetchType, path: Binding<NavigationPath>, modelContext: ModelContext) {
    self.appState = appState
    self.feedController = FeedViewController(appState: appState, fetchType: fetchType, path: path, modelContext: modelContext)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    // Add the feed controller as a child
    addChild(feedController)
    view.addSubview(feedController.view)
    feedController.didMove(toParent: self)

    // Set up constraints - extend under navigation bar for proper large title behavior
    feedController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      feedController.view.topAnchor.constraint(equalTo: view.topAnchor),
      feedController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      feedController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      feedController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    // Apply theme
    applyTheme()
    
    // Load content immediately like FeedView does
    Task { @MainActor in
      await loadContentImmediately()
    }
  }
  
  @MainActor
  private func loadContentImmediately() async {
    // Get or create feed model like FeedView does
    let feedModel = FeedModelContainer.shared.getModel(for: feedController.fetchType, appState: appState)
    
    // If the model already has posts, load them immediately
    if !feedModel.posts.isEmpty {
      let filteredPosts = feedModel.applyFilters(withSettings: appState.feedFilterSettings)
      await feedController.loadPostsDirectly(filteredPosts)
    } else {
      // DISABLED: SwiftUI handles all loading
      // UIKit should wait for SwiftUI to provide posts
      print("UIKitFeedView: No posts available yet, waiting for SwiftUI to provide them")
    }
  }
  
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    
    // Ensure proper navigation bar integration for large title behavior
    if let navigationController = navigationController {
      // Force the collection view to extend under the navigation bar
      extendedLayoutIncludesOpaqueBars = true
      
      // Make sure the feed controller's collection view has proper content inset behavior
      feedController.collectionView.contentInsetAdjustmentBehavior = .automatic
    }
  }

  private func applyTheme() {
    let currentScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
    let effectiveScheme = appState.themeManager.effectiveColorScheme(for: currentScheme)
    view.backgroundColor = .clear  // Let SwiftUI .themedPrimaryBackground() handle this
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)

    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      applyTheme()
    }
  }
}
