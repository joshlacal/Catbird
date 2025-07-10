# Task: Fix Feeds Start Page Header Scaling

## Priority: HIGH

## Issue Description
Feeds start page header is broken, not scaling properly, and stuck at an incorrect size.

## Investigation Steps
1. Examine feeds start page header implementation
2. Check responsive design and scaling logic
3. Review layout constraints and modifiers
4. Test on different screen sizes

## Key Files to Examine
- `Catbird/Features/Feed/Views/FeedsStartPage.swift`
- `Catbird/Features/Feed/Views/FeedDiscoveryHeaderView.swift`
- `Catbird/Features/Feed/ViewModels/FeedsStartPageViewModel.swift`
- `Catbird/Features/Feed/Views/HeaderFeedView.swift`

## Expected Outcome
Header should scale properly across different screen sizes and orientations.