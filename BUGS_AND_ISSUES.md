# Catbird Bug Tracker

## Critical Issues

### 🔄 View Refresh Problems
- **Post Creation**: ✅ FIXED - Timeline now refreshes automatically after posting (fixed guard clause in FeedModel.refreshFeedAfterEvent)
- **Thread Replies**: Replying in a thread doesn't show the new reply immediately
- **Account Switching**: 
  - Feeds don't switch/refresh when switching accounts
  - Chat doesn't immediately refresh after account switch
  - Search history persists across accounts (should be separate per account)

### 📱 Feed Behavior Issues
- **Over-eager Refresh**: Feeds refresh too frequently and jump to top
- **Scroll Position**: App doesn't maintain scroll position when backgrounded and resumed
- **Feed Persistence**: Last used feed not persisted in state/AppStorage

### ❌ Error Handling & States
- **Poor Error States**: Error handling is inconsistent across the app
- **Content Unavailable Views**: Underutilized - not showing when they should
- **Error Propagation**: Errors not properly bubbled up to UI
- **Cache State Clarity**: App shows cached content without indicating current connection state
- **Blank Threads**: Client crashes/issues result in blank threads with cached content

## UI/UX Issues

### 🎨 Design Consistency
- **Spacing**: Inconsistent spacing throughout the app
- **Content Headers**: Feeds not subscribed to need proper headers with:
  - Feed icon and name
  - Description
  - Creator information
  - Subscribe/Report buttons

### 🔍 Search Improvements
- Search view needs overall improvement
- Search history should be per-account, not global

### 💬 Chat/Messages
- **Badges**: Add notification badges to messages tab
- **Local Notifications**: Poll for chat messages locally
- **Message Requests**: Improve handling and notifications

## Feature Gaps

### 📊 Embeddings
- Implement post embeddings support

### ⚙️ Settings
- Settings need cleanup and expansion
- More comprehensive preference options

### 🛠️ Developer Tools
- **In-App Logging**: Improve logging system
- **Debug Tools**: Add message log viewer
- **Network State**: Better indication of connection status
- **Cache Management**: Tools to view/clear cache state

## Technical Debt

### 🔍 Debugging & Monitoring
- Better error tracking and reporting
- Improved crash handling
- Network state monitoring
- Cache invalidation strategies

### 📱 State Management
- Feed state persistence
- Better account switching state management
- Proper view refresh triggers

---

*Last Updated: January 27, 2025*
*Priority: 🔴 Critical | 🟡 Medium | 🟢 Low*