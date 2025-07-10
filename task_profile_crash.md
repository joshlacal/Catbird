# Task: Fix Profile Crashes on Visit

## Priority: HIGH

## Issue Description
Profile crashes are occurring when visiting user profiles, preventing users from accessing profile information.

## Investigation Steps
1. Search for profile-related views and view models
2. Check crash logs or error patterns
3. Examine navigation flow to profiles
4. Review memory management in profile views

## Key Files to Examine
- `Catbird/Features/Profile/Views/UnifiedProfileView.swift`
- `Catbird/Features/Profile/Views/UIKit/UIKitProfileView.swift`
- `Catbird/Features/Profile/ViewModels/ProfileViewModel.swift`
- `Catbird/Core/Navigation/NavigationDestination.swift`

## Expected Outcome
Profile views should load without crashes and display user information properly.