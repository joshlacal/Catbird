//
//  FeedWithNewPostsIndicator.swift
//  Catbird
//
//  Container view that combines FeedCollectionView with NewPostsIndicator
//

import SwiftUI

@available(iOS 16.0, macOS 13.0, *)
struct FeedWithNewPostsIndicator: View {
  let stateManager: FeedStateManager
  @Binding var navigationPath: NavigationPath
  let onScrollOffsetChanged: ((CGFloat) -> Void)?
  
  init(
    stateManager: FeedStateManager,
    navigationPath: Binding<NavigationPath>,
    onScrollOffsetChanged: ((CGFloat) -> Void)? = nil
  ) {
    self.stateManager = stateManager
    self._navigationPath = navigationPath
    self.onScrollOffsetChanged = onScrollOffsetChanged
  }
  
  var body: some View {
    ZStack {
      // Main feed collection view
      FeedCollectionView(
        stateManager: stateManager,
        navigationPath: $navigationPath,
        onScrollOffsetChanged: onScrollOffsetChanged
      )
      
      // New posts indicator overlay with dynamic island & safe area awareness
      if stateManager.hasNewPosts && stateManager.newPostsCount > 0 {
        GeometryReader { geometry in
          VStack {
              Spacer(minLength: 25)
            HStack {
              Spacer()
              
              NewPostsIndicator(
                newPostsCount: stateManager.newPostsCount,
                authorAvatars: stateManager.newPostsAuthorAvatars,
                onActivate: {
                  Task { @MainActor in
                    await handleScrollToTop()
                  }
                }
              )
              .padding(.trailing, 16)
              .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .opacity
              ))
              // Removed .id() modifier to prevent forced view recreation
              
              Spacer()
            }
            .padding(.top, calculateDynamicIslandAwareTopPadding(geometry: geometry))
            
            Spacer()
          }
        }
        .allowsHitTesting(true)
        .zIndex(1000) // Ensure it's on top
        .onAppear {
          print("🟡 NEW_POSTS_INDICATOR: FeedWithNewPostsIndicator appeared - hasNewPosts=\(stateManager.hasNewPosts), count=\(stateManager.newPostsCount), avatars=\(stateManager.newPostsAuthorAvatars.count)")
        }
        .onChange(of: stateManager.hasNewPosts) { oldValue, newValue in
          print("🔄 NEW_POSTS_INDICATOR: hasNewPosts changed from \(oldValue) to \(newValue) - count=\(stateManager.newPostsCount), avatars=\(stateManager.newPostsAuthorAvatars.count)")
          if newValue && stateManager.newPostsCount > 0 {
            print("✅ NEW_POSTS_INDICATOR: Should be showing indicator now!")
          }
        }
        .onChange(of: stateManager.newPostsCount) { oldValue, newValue in
          print("🔢 NEW_POSTS_INDICATOR: newPostsCount changed from \(oldValue) to \(newValue) - hasNewPosts=\(stateManager.hasNewPosts)")
        }
      } else {
        // Debug empty state
        Color.clear
          .frame(height: 0)
          .onAppear {
            if stateManager.hasNewPosts || stateManager.newPostsCount > 0 {
              print("⚠️ NEW_POSTS_INDICATOR: Inconsistent state - hasNewPosts=\(stateManager.hasNewPosts), count=\(stateManager.newPostsCount)")
            }
          }
      }
    }
    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: stateManager.hasNewPosts)
  }
  
  // MARK: - Dynamic Island & Safe Area Calculations
  
  private func calculateDynamicIslandAwareTopPadding(geometry: GeometryProxy) -> CGFloat {
    let safeAreaTop = geometry.safeAreaInsets.top
    let deviceModel = PlatformDeviceInfo.userInterfaceIdiom
    
    // CRITICAL FIX: Account for navigation bar height, not just safe area
    // Navigation bar in iOS is typically 44pt tall, plus we need spacing
    let navigationBarHeight: CGFloat = 44
    let additionalSpacing: CGFloat = 8
    
    // Start with safe area + navigation bar + spacing
    var topPadding = safeAreaTop + navigationBarHeight + additionalSpacing
    
    // Dynamic Island detection for iPhone 14 Pro/Pro Max/15 Pro/Pro Max/16 Pro/Pro Max
    if deviceModel == .phone && isDynamicIslandDevice() {
      // For Dynamic Island devices, ensure we're clear of both the island and nav bar
      let dynamicIslandClearance: CGFloat = 44 // Height of dynamic island
      let totalDynamicIslandPadding = safeAreaTop + dynamicIslandClearance + navigationBarHeight + additionalSpacing
      topPadding = max(topPadding, totalDynamicIslandPadding)
      
      print("🏝️ DYNAMIC ISLAND: safeAreaTop=\(safeAreaTop), navBar=\(navigationBarHeight), total=\(totalDynamicIslandPadding)")
    }
    
    // For devices without large titles or in compact state, use minimum viable padding
    let minimumPadding = safeAreaTop + navigationBarHeight + 4 // Tighter spacing when nav bar is collapsed
    topPadding = max(topPadding, minimumPadding)
    
    print("📱 POSITIONING: safeAreaTop=\(safeAreaTop), navBarHeight=\(navigationBarHeight), finalPadding=\(topPadding)")
    print("🎯 NEW_POSTS_INDICATOR: Final top padding calculated as \(topPadding) for device with safeArea=\(safeAreaTop)")
    
    return topPadding
  }
  
  private func isDynamicIslandDevice() -> Bool {
    // Check for Dynamic Island devices by screen dimensions and iOS version
    #if os(iOS)
    return PlatformScreenInfo.hasDynamicIsland
    #else
    return false // macOS doesn't have Dynamic Island
    #endif
  }
  
  @MainActor
  private func handleScrollToTop() async {
    // Clear the new posts indicator and trigger scroll via callback
    stateManager.scrollToTopAndClearNewPosts()
  }
}

// MARK: - Convenience Initializers

@available(iOS 16.0, macOS 13.0, *)
extension FeedWithNewPostsIndicator {
  /// Creates a feed with new posts indicator using just the essential parameters
  init(
    stateManager: FeedStateManager,
    navigationPath: Binding<NavigationPath>
  ) {
    self.init(
      stateManager: stateManager,
      navigationPath: navigationPath,
      onScrollOffsetChanged: nil
    )
  }
}
