# Feed Discovery Improvements Plan

## Overview
The current feed discovery experience needs a complete overhaul to make it more intuitive and engaging for users. This document outlines the improvements needed.

## Key Features Needed

### 1. Onboarding Flow
- Interactive tutorial when first discovering feeds
- Guided walkthrough of how feeds work
- Sample content preview before subscribing

### 2. Swipable Feed Previews
- Card-based interface for browsing feeds
- Live preview of recent posts from each feed
- Swipe right to subscribe, left to skip
- Visual indicators for feed activity level

### 3. Explainers and Information Sheets
- Bottom sheet with detailed feed information
- Creator information and statistics
- Feed algorithm explanation (if available)
- Content warnings and moderation info
- User reviews/ratings

### 4. Interest-Based Discovery
- Leverage Bluesky's `InterestsPref` model (found in `AppBskyActorDefs.InterestsPref`)
- Surface feeds based on user's selected interests/tags
- Machine learning recommendations based on subscribed feeds
- Trending feeds in user's interest categories

## Technical Implementation

### Existing Models to Leverage
```swift
// From Petrel/Sources/Petrel/Generated/AppBskyActorDefs.swift
public struct InterestsPref: ATProtocolCodable, ATProtocolValue {
    public static let typeIdentifier = "app.bsky.actor.defs#interestsPref"
    public let tags: [String]
}
```

### UI Components Needed
1. **FeedPreviewCard**: Swipable card showing feed preview
2. **FeedOnboardingFlow**: Step-by-step introduction
3. **FeedDetailsSheet**: Comprehensive feed information
4. **InterestSelector**: Tag-based interest selection
5. **FeedRecommendationEngine**: Algorithm for suggesting feeds

### Data Flow
1. Fetch user's interests from preferences
2. Query feeds matching those interests
3. Rank by relevance and popularity
4. Present in swipable interface
5. Track user interactions for better recommendations

## Current Implementation Status
- ✅ Basic feed discovery with search
- ✅ Subscribe/unsubscribe functionality
- ✅ State invalidation for automatic refresh
- ❌ Onboarding flow
- ❌ Swipable previews
- ❌ Interest-based recommendations
- ❌ Detailed feed information sheets

## Priority Order
1. Interest-based discovery (leverage existing Bluesky data)
2. Swipable preview cards
3. Detailed information sheets
4. Full onboarding flow

## Notes
- The current `AddFeedSheet` is functional but lacks engagement
- Users need to understand what they're subscribing to before committing
- Visual previews are crucial for feed discovery
- Interest tags should be prominently displayed and filterable