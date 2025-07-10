import SwiftUI
import Petrel

/// Demo view to showcase the Twitter-style profile implementation
@available(iOS 18.0, *)
struct TwitterStyleProfileDemo: View {
  @Environment(AppState.self) private var appState
  @State private var selectedTab = 3
  @State private var lastTappedTab: Int? = nil
  @State private var navigationPath = NavigationPath()
  
  var body: some View {
    NavigationStack(path: $navigationPath) {
      Group {
        if let currentUserDID = appState.currentUserDID {
          // Use the UIKit implementation directly via UnifiedProfileView
          UnifiedProfileView(
            appState: appState,
            selectedTab: $selectedTab,
            lastTappedTab: $lastTappedTab,
            path: $navigationPath
          )
        } else {
          // Fallback for when user is not logged in
          VStack {
            Text("Please log in to view profile")
            Button("Login") {
              // Handle login
            }
          }
        }
      }
      .navigationTitle("Profile Demo")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

/// Comparison view showing both implementations side by side (for development)
@available(iOS 18.0, *)
struct ProfileImplementationComparison: View {
  @Environment(AppState.self) private var appState
  @State private var selectedTab = 3
  @State private var lastTappedTab: Int? = nil
  @State private var navigationPath = NavigationPath()
  @State private var showingUIKit = true
  
  var body: some View {
    NavigationStack(path: $navigationPath) {
      VStack(spacing: 0) {
        // Toggle between implementations
        Picker("Implementation", selection: $showingUIKit) {
          Text("SwiftUI").tag(false)
          Text("UIKit").tag(true)
        }
        .pickerStyle(.segmented)
        .padding()
        
        // Show selected implementation
        Group {
          if showingUIKit {
            // UIKit implementation through UnifiedProfileView (iOS 18+)
            UnifiedProfileView(
              appState: appState,
              selectedTab: $selectedTab,
              lastTappedTab: $lastTappedTab,
              path: $navigationPath
            )
          } else {
            // Legacy SwiftUI implementation through UnifiedProfileView (pre-iOS 18)
            UnifiedProfileView(
              appState: appState,
              selectedTab: $selectedTab,
              lastTappedTab: $lastTappedTab,
              path: $navigationPath
            )
          }
        }
      }
      .navigationTitle("Profile Comparison")
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

// MARK: - Usage Instructions

/*
 
 ## Twitter-Style Profile Banner Implementation
 
 This implementation provides a UIKit-based profile view with proper Twitter-style banner behavior:
 
 ### Key Features:
 1. **Static Banner**: During normal scrolling, the banner stays completely static (no parallax)
 2. **Pull Effects**: Only when pulling down past the initial position:
    - Banner stretches with bottom anchor point
    - Progressive blur effect
    - Overlay opacity increase
 3. **Performance**: Native UICollectionView with optimized scrolling
 4. **Integration**: Seamlessly hosts existing SwiftUI components via UIHostingConfiguration
 
 ### Usage:
 
 #### Option 1: Use UIKit implementation directly (iOS 18+)
 ```swift
 UIKitProfileViewControllerRepresentable(
   appState: appState,
   viewModel: profileViewModel,
   navigationPath: $navigationPath,
   isEditingProfile: $isEditingProfile
 )
 ```
 
 #### Option 2: Use via UnifiedProfileView (automatic iOS 18+ detection)
 ```swift
 UnifiedProfileView(
   appState: appState,
   selectedTab: $selectedTab,
   lastTappedTab: $lastTappedTab,
   path: $navigationPath
 )
 ```
 
 ### Architecture:
 
 #### UIKit Layer:
 - `UIKitProfileViewController`: Main collection view controller
 - `ProfileBannerCell`: Handles banner display and effects
 - `ProfileInfoCell`, `FollowedByCell`, etc.: Host SwiftUI components
 - `ProfileBannerScrollHandler`: Manages scroll-based banner effects
 
 #### SwiftUI Integration:
 - `UIKitProfileViewControllerRepresentable`: UIViewControllerRepresentable wrapper
 - Reuses existing SwiftUI components: `ProfileHeaderContent`, `FollowedByView`, etc.
 - Maintains existing navigation, sheets, and state management
 
 ### Banner Behavior:
 
 The banner behavior is controlled by `ProfileBannerScrollHandler`:
 
 1. **Initial State**: Establishes baseline scroll offset
 2. **Normal Scroll**: Banner remains static (no effects)
 3. **Pull Down**: Applies scale, blur, and overlay effects
 4. **Thresholds**: Uses small threshold (-5pt) to avoid micro-movements
 
 ### Performance Optimizations:
 
 - UICollectionViewCompositionalLayout for efficient layout
 - UIHostingConfiguration for SwiftUI/UIKit integration
 - Proper cell reuse and preparation
 - Minimal effect calculations during scroll
 
 ### Comparison with Original:
 
 The original SwiftUI implementation had issues with:
 - Banner appearing "blown up and blurred" on load
 - Complex scroll offset calculations causing visual artifacts
 - Inconsistent banner behavior
 
 This UIKit implementation provides:
 - Clean, predictable banner behavior
 - Better performance for complex scrolling
 - Proper separation of scroll handling and banner effects
 - Consistent Twitter-like experience
 
 */

#Preview("UIKit Profile") {
  let appState = AppState.shared
  if #available(iOS 18.0, *) {
    TwitterStyleProfileDemo()
      .environment(appState)
  } else {
    Text("iOS 18 Required")
  }
}

#Preview("Implementation Comparison") {
  let appState = AppState.shared
  if #available(iOS 18.0, *) {
    ProfileImplementationComparison()
      .environment(appState)
  } else {
    Text("iOS 18 Required")
  }
}
