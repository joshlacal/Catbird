# Task: Fix Stretchable Header Effect

## Priority: MEDIUM

## Issue Description
Stretchable header effect is broken, preventing the expected interactive header behavior during scrolling.

## Investigation Steps
1. Search for stretchable header implementations
2. Check scroll view interactions
3. Review header animation and transform logic
4. Test scroll-to-refresh and header stretching

## Key Files to Examine
- `Catbird/Features/Feed/Views/HeaderFeedView.swift`
- `Catbird/Features/Feed/Views/UIKitFeedView.swift`
- `Catbird/Core/UI/ThemedViewModifiers.swift`
- Profile header implementations

## Expected Outcome
Headers should stretch and animate properly during scroll interactions.