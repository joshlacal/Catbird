# Profile View Architecture

Catbird uses `UnifiedProfileView` (pure SwiftUI) for all profile displays across iOS and macOS, supporting both the authenticated user and third-party profiles.

## Active Architecture

Profile components reside in `Features/Profile/Views/Unified/`:
- `UnifiedProfileView` — SwiftUI container coordinating navigation, sheets (reporting, lists, account switcher, copilot), toolbar actions, and lifecycle loads.
- `UnifiedProfileContentView` — Main content scroll view hosting banner, profile header, tab selector, and feed sections.
- `ProfileHeader` / `ProfileBannerHeader` — Header rendering avatar, banner imagery, display names, follower/following metrics, and action controls.
- `ProfileTab` (`Core/Navigation/ProfileTab.swift`) — Shared navigation model defining tabs (`posts`, `replies`, `media`, `likes`, `feeds`, `lists`, `starterPacks`, `labelerInfo`).

## Historical Note: Retired UIKit Implementation

An earlier UIKit-based profile cluster (`ProfileViewController`, `ProfileCollectionViewController`, `ProfileTabBar`, `ProfileBannerView`, `UIKitProfileView`) under `Features/Profile/Views/UIKit/` was introduced to test `UICollectionViewCompositionalLayout` elastic banner physics and sticky tab bar behaviors.

That experimental cluster was disconnected from app navigation and has been removed. Profile presentation is handled natively in SwiftUI.