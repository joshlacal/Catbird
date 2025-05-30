# Catbird Bug Fix Implementation Plan

## Executive Summary

This plan addresses critical state management, error handling, and UX issues in Catbird through a systematic 4-phase approach. The root cause analysis reveals that most refresh problems stem from improper state invalidation and view updates in the @Observable architecture.

## Root Cause Analysis

### Primary Issues
1. **State Fragmentation**: Views maintain isolated state that doesn't sync
2. **Missing Invalidation**: Mutations don't trigger dependent view updates  
3. **Account Switch Cascade**: State doesn't properly reset across components
4. **Poor Error Boundaries**: Failures result in blank content instead of clear errors

### Technical Architecture Problems
- FeedModel instances are isolated per view
- PostShadowManager handles mutations but doesn't notify feeds
- No central event coordination system
- Inconsistent @Observable usage patterns

## Implementation Phases

### Phase 1: Foundation (Week 1-2)
**Goal**: Establish robust state management and debugging infrastructure

#### Tasks
- [ ] **State Architecture Audit**
  - Analyze current AppState, FeedModel, PostShadowManager usage
  - Document state dependency graph
  - Identify @Observable pattern violations

- [ ] **Central Event Bus Implementation**
  ```swift
  @Observable
  class AppState {
      private let eventBus = StateInvalidationBus()
      
      func postCreated(_ post: Post) {
          eventBus.notify(.postCreated(post))
      }
      
      func accountSwitched() {
          eventBus.notify(.accountChanged)
      }
  }
  ```

- [ ] **Logging Infrastructure**
  ```swift
  extension OSLog {
      static let stateManagement = OSLog(subsystem: "Catbird", category: "State")
      static let feedUpdates = OSLog(subsystem: "Catbird", category: "Feed")
      static let accountSwitch = OSLog(subsystem: "Catbird", category: "Auth")
  }
  ```

- [ ] **Debug Tools**
  - Create DebugStateView for runtime inspection
  - Add network connectivity monitoring
  - State transition logging

#### Deliverables
- StateInvalidationBus implementation
- Comprehensive logging system
- Debug state viewer
- Architecture documentation

### Phase 2: Core Refresh Fixes (Week 2-3)
**Goal**: Eliminate all major view refresh issues

#### Priority Fixes
1. **Post Creation → Timeline Update**
   ```swift
   // PostComposerViewModel
   func submitPost() async {
       let post = await postManager.create(content)
       appState.feedManager.invalidateFeeds(containing: post)
       appState.notifyPostCreated(post)
   }
   ```

2. **Thread Replies → Immediate Display**
   ```swift
   // ThreadManager
   func addReply(_ reply: Post, to thread: Thread) {
       thread.replies.append(reply)
       appState.notifyThreadUpdated(thread)
   }
   ```

3. **Account Switching → Full State Reset**
   ```swift
   // AuthManager
   func switchAccount() {
       feedManager.clearAll()
       chatManager.clearState()
       preferencesManager.switchUser()
       appState.notifyAccountChanged()
   }
   ```

#### Technical Implementation
- Event-driven state updates
- Optimistic UI updates with rollback
- Proper @MainActor usage
- State versioning for cache invalidation

#### Testing Strategy
- MCP simulator automated testing
- Screenshot-driven validation
- Log capture during state transitions
- Account switching integration tests

### Phase 3: Error Handling & UX (Week 3-4)
**Goal**: Standardize error states and improve user feedback

#### Components to Build
- **ErrorStateView**: Standardized error display
- **NetworkStateIndicator**: Connection status
- **ContentUnavailableView**: Proper empty states
- **LoadingStateView**: Consistent loading indicators

#### Error Handling Improvements
```swift
@Observable
class NetworkState {
    var isConnected: Bool = true
    var lastError: Error?
    var retryCount: Int = 0
    
    func handleError(_ error: Error) {
        lastError = error
        // Show user-friendly error instead of blank content
    }
}
```

#### Feed Headers for Unsubscribed Feeds
- Feed icon and name display
- Creator information
- Subscribe/Report buttons
- Description text

### Phase 4: UI Polish & Features (Week 4-5)
**Goal**: Address UX inconsistencies and missing features

#### Design System Improvements
- Spacing standardization audit
- Typography consistency
- Color usage guidelines
- Component library cleanup

#### Feature Enhancements
- **Search Improvements**
  - Per-account search history
  - Better typeahead
  - Advanced filters

- **Chat Enhancements**
  - Notification badges
  - Local polling for messages
  - Better message requests handling

- **Settings Cleanup**
  - Reorganize settings hierarchy
  - Add missing preferences
  - Improve accessibility options

## Testing & Validation Strategy

### Automated Testing with MCP Tools
```python
# Example test scenario
def test_post_creation_refresh():
    # Build and launch app
    build_run_ios_sim_name_proj(...)
    
    # Navigate to composer
    tap_compose_button()
    
    # Create post
    type_text("Test post content")
    tap_submit()
    
    # Verify immediate timeline update
    screenshot_timeline()
    assert_post_visible("Test post content")
    
    # Test profile refresh
    navigate_to_profile()
    assert_post_visible("Test post content")
```

### Success Metrics
- [ ] Post creation immediately visible in timeline
- [ ] Thread replies appear without manual refresh
- [ ] Account switching clears and refreshes all views
- [ ] Feeds maintain scroll position across app lifecycle
- [ ] Clear error states instead of blank content
- [ ] Consistent spacing and UI throughout app

### Validation Checklist
- [ ] All critical refresh bugs resolved
- [ ] Error states are clear and actionable
- [ ] Account switching works seamlessly
- [ ] Feed behavior is stable and predictable
- [ ] Search history is per-account
- [ ] Chat notifications work properly

## Implementation Timeline

| Week | Focus | Key Deliverables |
|------|-------|------------------|
| 1-2 | Foundation | StateInvalidationBus, Logging, Debug tools |
| 2-3 | Core Fixes | Post refresh, Account switching, Thread updates |
| 3-4 | Error Handling | Error components, Network states, Feed headers |
| 4-5 | UI Polish | Design consistency, Feature enhancements |

## Risk Mitigation

### Technical Risks
- **State management complexity**: Use simple event bus pattern
- **Performance impact**: Lazy loading and efficient invalidation
- **Regression risk**: Comprehensive testing at each phase

### Rollback Strategy
- Feature flags for major changes
- Incremental rollout
- Automated testing validation
- User feedback monitoring

## Next Steps

1. **Immediate (Today)**
   - Begin AppState architecture audit
   - Set up logging infrastructure
   - Create basic StateInvalidationBus

2. **Week 1**
   - Complete foundation layer
   - Test event bus with one refresh bug
   - Set up MCP testing framework

3. **Ongoing**
   - Daily testing with MCP tools
   - Log analysis for state transitions
   - User feedback integration

---

*This plan provides a systematic approach to resolving Catbird's core stability and UX issues while building a foundation for future feature development.*