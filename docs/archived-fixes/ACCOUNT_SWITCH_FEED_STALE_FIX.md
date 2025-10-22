# Account Switch Feed State Fix

## Problem
After centralizing `getFeedGenerator` calls in `FeedModel.swift`, switching accounts caused three issues:
1. **Stale feed content**: The feed would show posts from the previous account
2. **Incorrect feed name**: The UI would show "Feed" instead of the actual feed generator name, or show the previous account's feed name
3. **Wrong feed selection**: When switching accounts, it would try to show the same feed from the other account instead of remembering each account's last-used feed

## Root Cause Analysis

### Issue 1: Stale Content
- `FeedStateStore` caches `FeedStateManager` instances by feed identifier (e.g., `"at://did:plc:.../app.bsky.feed.generator/..."`)
- When switching accounts, if the same feed URI was selected, it would reuse the cached manager with the old account's data
- The cache was NOT scoped by user DID, so different accounts shared the same cached feed state
- While `FeedView` had an `.id()` modifier that included `currentUserDID`, the `FeedStateManager` was still cached globally

### Issue 2: Incorrect Feed Name
- `ContentView` sets `currentFeedName` to "Feed" as a placeholder
- `FeedModel.loadFeed()` fetches `feedGeneratorInfo` asynchronously
- There was NO mechanism to propagate the feed name from `FeedModel` back to `ContentView.currentFeedName`
- The feed generator info was fetched but never used to update the displayed title

### Issue 3: Wrong Feed Selection
- There was NO per-account memory of which feed was last selected
- When switching accounts, all versions would reset to Timeline or try to use the same feed as the previous account
- Each account should remember its own last-used feed independently

## Solution

### Part 1: Clear Feed State on Account Switch
**File: `Catbird/Core/Services/FeedStateStore.swift`**

Made `FeedStateStore` listen to account switch events:
1. Implement `StateInvalidationSubscriber` protocol
2. Subscribe to `StateInvalidationBus` when `AppState` is first set
3. Handle `.accountSwitched` event by calling `clearAllStateManagers()`
4. Unsubscribe in `deinit`

This ensures that when accounts switch, all cached feed managers are cleared, forcing fresh data to be loaded for the new account.

### Part 2: Per-Account Feed Memory with UserDefaults
**File: `Catbird/App/ContentView.swift`**

Added to all `MainContentView` variants (iOS 18, iOS 17, macOS):

**New Helper Functions:**
1. `saveLastFeedForAccount()`: Saves the current feed selection to UserDefaults with a key scoped to the current user DID
2. `restoreLastFeedForAccount()`: Loads the last feed for the current account from UserDefaults
3. `loadDefaultFeed()`: Fallback to load first pinned feed or timeline if no saved feed exists

**Storage Format:**
- Key: `"lastSelectedFeed_<userDID>"`
- Value: Feed identifier string
  - Timeline: `"timeline"`
  - Custom feed: `"at://did:plc:..."`
  - List: `"list:<uri>:<name>"`

**onChange Handlers:**
1. `.onChange(of: appState.currentUserDID)`: When account switches, restore last feed for new account
2. `.onChange(of: selectedFeed)`: Save feed selection whenever user changes feeds

### Part 3: Fetch and Update Feed Name
**File: `Catbird/App/ContentView.swift`**

Added to all `MainContentView` variants:
1. `.task(id: selectedFeed)` that:
   - Runs whenever `selectedFeed` changes
   - For custom feeds (`.feed(uri)`): Fetches feed generator info and updates `currentFeedName` with the display name
   - For timeline: Sets `currentFeedName` to "Timeline"
   - For lists: Sets `currentFeedName` to the list name

This ensures the feed name is always up-to-date and fetched independently of the feed loading process.

## Benefits

1. **Clean state separation**: Each account gets fresh feed state
2. **Correct feed names**: Feed names are fetched and displayed immediately when feeds are selected
3. **No stale content**: Feed content is cleared and reloaded when switching accounts
4. **Per-account feed memory**: Each account remembers its last-used feed independently
5. **Seamless UX**: Switching accounts feels natural - you return to exactly where you were
6. **Consistent behavior**: Works across all iOS versions (17, 18) and macOS

## Testing Recommendations

1. **Account switching test**:
   - Add two accounts (Account A, Account B)
   - On Account A, select a custom feed "Discover"
   - Switch to Account B
   - Verify: Shows Account B's last-used feed (or Timeline if first time)
   - Select a different custom feed "Science"
   - Switch back to Account A
   - Verify: Shows "Discover" feed again (Account A's last selection)
   - Verify: Feed content is from Account A, not Account B

2. **Feed name display test**:
   - Select various custom feeds
   - Verify feed names appear correctly (not "Feed")
   - Verify names update when switching between feeds
   - Switch accounts and verify feed names are correct for the new account

3. **State persistence test**:
   - Select a custom feed on Account A
   - Kill and restart the app
   - Verify: Account A still shows the same custom feed
   - Switch to Account B
   - Select a different feed
   - Kill and restart the app
   - Verify: Account B shows its selected feed

4. **First-time account test**:
   - Add a brand new account
   - Verify: Shows first pinned feed or Timeline (not another account's feed)
   - Select a custom feed
   - Switch away and back
   - Verify: New account remembers its selection

## Implementation Notes

- The fix uses the existing `StateInvalidationBus` infrastructure for clean event propagation
- Feed name fetching is independent of feed data loading, preventing race conditions
- The solution maintains the existing caching strategy while properly scoping it to accounts
- Per-account feed memory uses UserDefaults with keys scoped by user DID
- All three UI variants (iOS 18, iOS 17, macOS) receive identical fixes for consistency
- The restore logic gracefully handles missing or invalid saved feeds by falling back to defaults

## Related Files

- `Catbird/Core/Services/FeedStateStore.swift` - Feed state caching and account switch handling
- `Catbird/App/ContentView.swift` - UI state management, feed name updates, and per-account feed memory
- `Catbird/Features/Feed/Models/FeedModel.swift` - Feed generator info fetching (unchanged, centralized calls remain)
- `Catbird/Features/Feed/Views/FeedView.swift` - Feed display (unchanged)
- `Catbird/Core/UI/HomeView.swift` - Home view (unchanged)
