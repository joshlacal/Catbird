//
//  UIKitNavigationController.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/4/25.
//

import UIKit
import SwiftUI
import SwiftData

// MARK: - Full UIKit Navigation Wrapper

/// A complete UIKit navigation controller that provides native navigation bar behavior
struct FullUIKitNavigationWrapper: UIViewControllerRepresentable {
  let appState: AppState
  let fetchType: FetchType
  let feedName: String
  @Binding var path: NavigationPath
  let onScrollOffsetChanged: ((CGFloat) -> Void)?
  let isDrawerOpenBinding: Binding<Bool>
  let showingSettingsBinding: Binding<Bool>
@Environment(\.modelContext) private var modelContext
    
  func makeUIViewController(context: Context) -> UIKitNavigationController {
    let controller = UIKitNavigationController(
      appState: appState,
      fetchType: fetchType,
      feedName: feedName,
      path: $path,
      isDrawerOpenBinding: isDrawerOpenBinding,
      showingSettingsBinding: showingSettingsBinding,
        modelContext: modelContext
    )
    controller.feedController.onScrollOffsetChanged = onScrollOffsetChanged
    return controller
  }

  func updateUIViewController(_ uiViewController: UIKitNavigationController, context: Context) {
    // Update scroll offset callback
    uiViewController.feedController.onScrollOffsetChanged = onScrollOffsetChanged

    // Update navigation title if changed
    if uiViewController.feedController.title != feedName {
      uiViewController.feedController.title = feedName
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


// MARK: - UIKit Navigation Controller

/// A UIKit navigation controller that provides complete control over navigation behavior
@available(iOS 18.0, *)
final class UIKitNavigationController: UINavigationController {
  let feedController: FeedViewController
  private let appState: AppState
  private let isDrawerOpenBinding: Binding<Bool>
  private let showingSettingsBinding: Binding<Bool>
  private let navigationPath: Binding<NavigationPath>
  private var navigationObservation: Any?
  private var lastPathCount = 0
  private var navigationPathTimer: Timer?

  init(
    appState: AppState,
    fetchType: FetchType,
    feedName: String,
    path: Binding<NavigationPath>,
    isDrawerOpenBinding: Binding<Bool>,
    showingSettingsBinding: Binding<Bool>,
    modelContext: ModelContext
  ) {
    self.appState = appState
    self.isDrawerOpenBinding = isDrawerOpenBinding
    self.showingSettingsBinding = showingSettingsBinding
    self.navigationPath = path
    self.feedController = FeedViewController(appState: appState, fetchType: fetchType, path: path, modelContext: modelContext)

    super.init(nibName: nil, bundle: nil)

    // Set the feed controller as the root view controller
    viewControllers = [feedController]

    // Configure the navigation bar
    setupNavigationBar()

    // Set the navigation title
    feedController.title = feedName

    // Set up navigation bridge
    setupNavigationBridge()
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    // Apply theme
    applyTheme()

    // Setup toolbar items
    setupToolbarItems()

    // Configure collection view for large title behavior
    if let collectionView = feedController.collectionView {
      // Critical: Collection view must be the first subview and aligned to top
      // This is required for large title collapse behavior to work properly
      collectionView.contentInsetAdjustmentBehavior = .automatic
      collectionView.scrollsToTop = true
    }

    // Navigation is now handled by SwiftUI NavigationStack in the hybrid approach
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)

    // Ensure navigation bar is configured properly
    navigationBar.prefersLargeTitles = true
    feedController.navigationItem.largeTitleDisplayMode = .automatic

    // Apply custom fonts
    NavigationFontConfig.applyFonts(to: navigationBar)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)

    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      applyTheme()
    }
  }

  private func setupNavigationBar() {
    // Enable large titles
    navigationBar.prefersLargeTitles = true

    // Use the global navigation bar appearance set by ThemeManager
    // instead of creating our own custom appearance that conflicts
    let globalStandardAppearance = UINavigationBar.appearance().standardAppearance
    let globalScrollEdgeAppearance =
      UINavigationBar.appearance().scrollEdgeAppearance ?? globalStandardAppearance
    let globalCompactAppearance =
      UINavigationBar.appearance().compactAppearance ?? globalStandardAppearance

    // Apply the global appearances to this specific navigation bar
    navigationBar.standardAppearance = globalStandardAppearance
    navigationBar.scrollEdgeAppearance = globalScrollEdgeAppearance
    navigationBar.compactAppearance = globalCompactAppearance
  }

  private func currentColorScheme() -> ColorScheme {
    let systemScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
    // Use ThemeManager's effective color scheme to account for manual overrides
    return appState.themeManager.effectiveColorScheme(for: systemScheme)
  }

  private func setupToolbarItems() {
    // Leading toolbar item - feeds drawer
    let feedsButton = UIBarButtonItem(
      image: UIImage(systemName: "circle.grid.3x3.circle"),
      style: .plain,
      target: self,

      action: #selector(openDrawer)
    )
    feedsButton.tintColor = UIColor(
      Color.dynamicText(appState.themeManager, style: .primary, currentScheme: currentColorScheme())
    )

    // Trailing toolbar item - settings avatar
    let avatarButton = UIBarButtonItem(
      image: UIImage(systemName: "person.circle"),
      style: .plain,
      target: self,
      action: #selector(openSettings)
    )
    avatarButton.tintColor = UIColor(
      Color.dynamicText(appState.themeManager, style: .primary, currentScheme: currentColorScheme())
    )

    // Set the navigation items
    feedController.navigationItem.leftBarButtonItem = feedsButton
    feedController.navigationItem.rightBarButtonItem = avatarButton
  }

  @objc private func openDrawer() {
    isDrawerOpenBinding.wrappedValue = true
  }

  @objc private func openSettings() {
    showingSettingsBinding.wrappedValue = true
  }

  private func applyTheme() {
    let isDarkMode = traitCollection.userInterfaceStyle == .dark
    let effectiveScheme = appState.themeManager.effectiveColorScheme(
      for: isDarkMode ? .dark : .light)

    view.backgroundColor = .clear  // Let SwiftUI .themedPrimaryBackground() handle this

    // Reapply navigation bar theme
    setupNavigationBar()

    // Update toolbar item colors
    setupToolbarItems()
  }

  // MARK: - SwiftUI Navigation Integration

  private func setupNavigationBridge() {
    // Set up monitoring of the navigation path
    lastPathCount = navigationPath.wrappedValue.count

    // Invalidate any existing timer
    navigationPathTimer?.invalidate()

    // Monitor navigation path changes
    navigationPathTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
      [weak self] timer in
      guard let self = self else {
        timer.invalidate()
        return
      }

      let currentPathCount = self.navigationPath.wrappedValue.count

      if currentPathCount != self.lastPathCount {
        self.handleNavigationPathChange(from: self.lastPathCount, to: currentPathCount)
        self.lastPathCount = currentPathCount
      }
    }
  }

  deinit {
    // Clean up navigation path timer
    navigationPathTimer?.invalidate()
  }

  private func handleNavigationPathChange(from oldCount: Int, to newCount: Int) {
    if newCount > oldCount {
      // Navigation forward - we need to use a different approach since we can't extract individual destinations
      // Let's fall back to SwiftUI navigation when needed
      fallbackToSwiftUINavigation()
    } else if newCount < oldCount {
      // Navigation back
      let targetCount = max(1, newCount + 1)  // +1 for root controller
      if viewControllers.count > targetCount {
        let targetViewController = viewControllers[targetCount - 1]
        popToViewController(targetViewController, animated: true)
      }
    }
  }

  private func fallbackToSwiftUINavigation() {
    // When SwiftUI navigation is needed, we can present a SwiftUI navigation stack
    // This is a hybrid approach that maintains UIKit nav bar for the main feed
    // but uses SwiftUI for detailed navigation

    // For now, we'll let the navigation be handled by the post views themselves
    // which can present modally or use other navigation patterns
  }

  // Method to handle navigation back to root
  override func popToRootViewController(animated: Bool) -> [UIViewController]? {
    // Also clear the SwiftUI navigation path
    DispatchQueue.main.async {
      self.navigationPath.wrappedValue = NavigationPath()
    }
    return super.popToRootViewController(animated: animated)
  }
}
