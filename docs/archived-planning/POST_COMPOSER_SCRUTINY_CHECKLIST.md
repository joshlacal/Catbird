# Post Composer Scrutiny Checklist for Parallel Agents

## Purpose
This document provides a structured framework for parallel agents to analyze, critique, and validate the post composer's URL handling logic and proposed solutions.

---

## Section 1: Current Implementation Analysis

### 1.1 State Management Review

**Question Set A: State Variable Purpose**
- [ ] Review `detectedURLs`, `urlCards`, `selectedEmbedURL`, `urlsKeptForEmbed`, `manualLinkFacets`
- [ ] Are these variables truly independent, or do they represent overlapping concerns?
- [ ] Can any of these be derived from others instead of being stored separately?
- [ ] What happens if these variables become out of sync? Are there safeguards?

**Question Set B: State Transitions**
- [ ] Map all code paths that modify `urlCards`
- [ ] Map all code paths that modify `selectedEmbedURL`  
- [ ] Map all code paths that modify `manualLinkFacets`
- [ ] Are there any unhandled edge cases in state transitions?
- [ ] Can we create an invalid state through user actions?

**Question Set C: Thread Safety**
- [ ] Are URL state variables accessed from multiple threads/actors?
- [ ] Is `@MainActor` isolation sufficient, or do we need more granular locking?
- [ ] Could race conditions occur between async URL card loading and sync text updates?
- [ ] Should `urlCards` be protected by an Actor?

### 1.2 Text Processing Pipeline Review

**Question Set D: Processing Flow**
- [ ] Trace the complete flow: User types → `updatePostContent()` → Parser → Facets → UI
- [ ] Identify all places where `updatePostContent()` is called
- [ ] Are there any circular dependencies or infinite loop risks?
- [ ] Is debouncing/throttling applied consistently?

**Question Set E: Facet Management**
- [ ] How are facets created from detected URLs?
- [ ] How are `manualLinkFacets` merged with parsed facets?
- [ ] What happens when byte ranges become invalid after text edits?
- [ ] Could facets overlap or conflict?

**Question Set F: Performance Characteristics**
- [ ] Is `PostParser.parsePostContent()` called too frequently?
- [ ] Are URL cards loaded synchronously or asynchronously?
- [ ] Could heavy editing cause performance issues?
- [ ] Is there excessive attributed string creation/copying?

### 1.3 UIKit Integration Review

**Question Set G: RichTextView Behavior**
- [ ] What does `dataDetectorTypes = .all` actually do?
- [ ] How does UIKit's automatic link detection interact with manual facets?
- [ ] When and why does `typingAttributes` inherit link styling?
- [ ] Are there other UITextView behaviors we're not accounting for?

**Question Set H: Coordinator Pattern**
- [ ] How is state synchronized between SwiftUI and UIKit layers?
- [ ] Could updates be lost or delayed in the bridging layer?
- [ ] Are all UITextViewDelegate methods properly handled?
- [ ] Is there risk of stale state in UIViewRepresentable updates?

---

## Section 2: Proposed Solution Validation

### 2.1 Fix 1: Clear Manual Link Facets

**Critique Points**:
- [ ] Does removing facets by URL matching handle all cases?
- [ ] What if the same URL appears multiple times in text?
- [ ] Could we accidentally remove facets for similar but different URLs?
- [ ] Is the facet removal code performant for long text with many URLs?

**Alternative Approaches**:
- [ ] Could we track facet ownership (manual vs parsed) with metadata?
- [ ] Should we clear ALL `manualLinkFacets` instead of filtering?
- [ ] Would it be safer to regenerate all facets from scratch?

**Edge Cases**:
- [ ] URL with URL-encoded characters: `https://example.com/path%20with%20spaces`
- [ ] URL fragments: `https://example.com#section`
- [ ] URL with query params: `https://example.com?foo=bar&baz=qux`
- [ ] Internationalized domain names (IDN)

### 2.2 Fix 2: Reset Typing Attributes

**Critique Points**:
- [ ] Is weak reference to `RichTextView` safe? Could it be deallocated unexpectedly?
- [ ] Should we reset typing attributes on EVERY text change, or just after URL removal?
- [ ] Are there other attributes besides font and color we should reset?
- [ ] Could this interfere with user-intended formatting (bold, italic, etc.)?

**Alternative Approaches**:
- [ ] Could we prevent link attribute inheritance at the UITextView level?
- [ ] Should we override `typingAttributes` getter/setter in RichTextView?
- [ ] Would it be better to use NSTextStorage delegate methods?

**Platform Considerations**:
- [ ] Does this approach work on macOS (NSTextView has different APIs)?
- [ ] Are typing attributes handled the same way across iOS versions?
- [ ] What about iPad with external keyboard?

### 2.3 Fix 3: Disable Data Detectors

**Critique Points**:
- [ ] What URLs does PostParser detect that UIKit wouldn't?
- [ ] What URLs does UIKit detect that PostParser wouldn't?
- [ ] Are there legitimate use cases for detecting phone numbers in social posts?
- [ ] Could disabling data detectors affect accessibility features?

**Testing Requirements**:
- [ ] Test suite for URL detection edge cases
- [ ] Compare PostParser vs UIKit detection on 1000+ sample texts
- [ ] Verify international URL formats work correctly
- [ ] Check punycode domain handling

**Rollback Strategy**:
- [ ] If we discover issues post-deployment, can we easily revert?
- [ ] Should this be behind a feature flag?
- [ ] Can we A/B test with/without data detectors?

### 2.4 Fix 4: Clear Facets on Manual Deletion

**Critique Points**:
- [ ] How do we detect "manual deletion" vs "programmatic deletion"?
- [ ] What if user undoes (Cmd+Z) a deletion?
- [ ] Could rapid typing trigger unwanted facet clearing?
- [ ] Is tracking `previousURLs` vs `currentURLs` sufficient?

**Memory Considerations**:
- [ ] Does creating Sets on every text change impact performance?
- [ ] Should we use `ContiguousArray` for better cache locality?
- [ ] Could we optimize the diffing algorithm?

**Concurrency Safety**:
- [ ] Is `handleDetectedURLsOptimized` always called on MainActor?
- [ ] Could text updates occur while URL processing is in flight?
- [ ] What happens if user types during async URL card loading?

---

## Section 3: Architectural Concerns

### 3.1 Sticky URL Cards Proposal

**Evaluation Questions**:
- [ ] Would sticky cards create confusion for users who manually delete URLs?
- [ ] How would we communicate "this card will be embedded but text is gone"?
- [ ] Could this lead to accidental embeds users don't want?
- [ ] Is the added complexity worth the UX improvement?

**Implementation Complexity**:
- [ ] Estimate engineering effort: small/medium/large/x-large?
- [ ] How many files would need changes?
- [ ] What's the testing surface area?
- [ ] Risk of regression in existing functionality?

**Alternative UX Patterns**:
- [ ] Could we show a preview pane instead of inline cards?
- [ ] Should URL cards be in a separate "Attachments" section?
- [ ] What do Twitter, Mastodon, Threads do?
- [ ] User research: do people want sticky cards?

### 3.2 Unified State Model Proposal

**Evaluation Questions**:
- [ ] Is `URLState` struct the right granularity?
- [ ] Should it be a class (reference type) or struct (value type)?
- [ ] How would this integrate with ThreadEntry persistence?
- [ ] What's the migration path from current state to new state?

**Data Consistency**:
- [ ] How do we ensure `urlStates` doesn't diverge from actual text content?
- [ ] Should we validate state invariants after each mutation?
- [ ] Could we use property observers to maintain consistency?
- [ ] Would a state machine model be clearer?

**Performance Impact**:
- [ ] Is dictionary lookup by URL string efficient enough?
- [ ] Should we use a more optimized data structure?
- [ ] How large can `urlStates` grow (max URLs per post)?
- [ ] Memory footprint acceptable for long posts with many URLs?

---

## Section 4: Testing Strategy

### 4.1 Unit Test Coverage

**Required Test Cases**:
- [ ] URL detection accuracy (100 diverse URL formats)
- [ ] Facet generation for various text layouts
- [ ] State persistence across thread entry switches
- [ ] Manual vs button deletion behavior
- [ ] Multiple URLs in single post
- [ ] Rapid text editing (stress test)
- [ ] Undo/redo operations
- [ ] Copy/paste of formatted text

**Mock Strategy**:
- [ ] How do we mock `ATProtoClient` for URL card loading?
- [ ] How do we simulate UITextView behavior in tests?
- [ ] Can we test UIKit integration without full UI tests?
- [ ] Should we use snapshot testing for visual verification?

### 4.2 Integration Test Scenarios

**Critical User Flows**:
- [ ] Compose post with URL → Remove text → Post → Verify embed present
- [ ] Compose thread → URLs in each entry → Verify correct embeds
- [ ] Draft post with URL → Close composer → Reopen → Verify state restored
- [ ] Paste URL → Edit text around it → Verify card stays
- [ ] Multiple URLs → Remove middle one → Verify others unaffected

**Error Scenarios**:
- [ ] URL card fails to load → User removes text → No crash
- [ ] Network timeout during card loading → State remains consistent
- [ ] Invalid URL pasted → No card generated → Text remains
- [ ] Extremely long URL (10KB+) → Parser doesn't hang

### 4.3 UI Test Automation

**Automation Scope**:
- [ ] Can we automate testing the blue text bug?
- [ ] How do we verify text color in UI tests?
- [ ] Can we test typing attributes programmatically?
- [ ] Should we use XCUITest or manual QA?

**Platform Coverage**:
- [ ] iOS 18+ on iPhone (all screen sizes)
- [ ] iOS 18+ on iPad
- [ ] macOS 13+ (SwiftUI text fields have different behavior)
- [ ] Dark mode vs light mode
- [ ] Accessibility: VoiceOver, Dynamic Type, Reduce Motion

---

## Section 5: User Experience Evaluation

### 5.1 Mental Model Alignment

**User Expectation Questions**:
- [ ] What do users expect when they delete a URL?
  - Card should disappear?
  - Card should stay?
  - Depends on how they delete it?
  
- [ ] What do users expect when they click "Remove link from text"?
  - URL text removed, card stays?
  - Both removed?
  - Unclear from button label?

- [ ] What do users expect when they see blue text?
  - It's a clickable link?
  - It will be clickable in the posted version?
  - It's just styling?

**Discoverability**:
- [ ] Is "Remove link from text" button easy to find?
- [ ] Is its function obvious from the icon/label?
- [ ] Should there be a tooltip/help text?
- [ ] Are there enough visual cues for embed vs facet distinction?

### 5.2 Error Recovery

**User Mistakes**:
- [ ] User accidentally removes URL card → How do they restore it?
- [ ] User removes URL text by mistake → Undo restores card?
- [ ] User confused by blue text → How do they fix it?
- [ ] User posts with wrong embed → Can they edit post?

**Error Messages**:
- [ ] URL card fails to load → Clear error message shown?
- [ ] Invalid URL detected → User informed?
- [ ] Network error → Retry option available?
- [ ] Rate limit hit → Appropriate feedback?

### 5.3 Accessibility

**Screen Reader Experience**:
- [ ] Are URL cards announced properly?
- [ ] Is "Remove link from text" button labeled?
- [ ] Can users navigate between card and text easily?
- [ ] Are facets/links announced correctly?

**Keyboard Navigation**:
- [ ] Can user tab to card buttons?
- [ ] Can user remove card with keyboard?
- [ ] Does focus management work correctly?
- [ ] Are keyboard shortcuts documented?

**Visual Accessibility**:
- [ ] Is blue link color sufficient contrast?
- [ ] Does color alone convey meaning (bad)?
- [ ] Do alternative visual cues exist?
- [ ] Does it work with Reduce Motion?

---

## Section 6: Performance & Scalability

### 6.1 Performance Benchmarks

**Metrics to Measure**:
- [ ] Time to parse text with N URLs (N = 1, 5, 10, 50)
- [ ] Time to generate facets for post of length L (L = 100, 500, 3000 chars)
- [ ] Memory usage with M URL cards loaded (M = 1, 5, 10)
- [ ] UI responsiveness during rapid typing (chars/sec handled smoothly)

**Acceptable Thresholds**:
- [ ] Text parsing: < 16ms (one frame at 60fps)
- [ ] URL card loading: < 500ms perceived wait
- [ ] State updates: < 5ms to maintain smooth typing
- [ ] Memory: < 10MB for typical post with 3 URLs

### 6.2 Worst Case Scenarios

**Stress Tests**:
- [ ] Post with 100 URLs (at AT Protocol limit)
- [ ] URL that's 10KB long (at some URL length limit)
- [ ] Typing at 200 WPM (very fast typist)
- [ ] Pasting 50KB of text with 20 URLs
- [ ] Loading 10 URL cards simultaneously

**Degradation Strategy**:
- [ ] What happens when we hit performance limits?
- [ ] Should we limit URL cards per post?
- [ ] Should we disable real-time parsing for long posts?
- [ ] Can we show loading states to manage expectations?

---

## Section 7: Code Quality Review

### 7.1 Maintainability

**Code Clarity**:
- [ ] Are variable names descriptive and unambiguous?
- [ ] Is the control flow easy to follow?
- [ ] Are there too many nested conditionals?
- [ ] Is error handling comprehensive?

**Documentation**:
- [ ] Are complex algorithms commented?
- [ ] Are state invariants documented?
- [ ] Are edge cases noted?
- [ ] Is there architectural documentation?

**Technical Debt**:
- [ ] Are there `// TODO:` or `// HACK:` comments?
- [ ] Are there temporary workarounds that should be fixed?
- [ ] Is there dead code that should be removed?
- [ ] Are there overly complex functions that should be refactored?

### 7.2 Swift 6 Compliance

**Concurrency**:
- [ ] Are all `@MainActor` annotations correct?
- [ ] Are there any data races according to Swift 6?
- [ ] Are sendable constraints satisfied?
- [ ] Is async/await used correctly throughout?

**Modern Swift Patterns**:
- [ ] Using `@Observable` instead of `ObservableObject`?
- [ ] Using structured concurrency (TaskGroup, etc.)?
- [ ] Using Swift 6 typed throws?
- [ ] Following Swift API design guidelines?

---

## Section 8: Security & Privacy

### 8.1 Security Concerns

**URL Handling**:
- [ ] Are we vulnerable to URL injection attacks?
- [ ] Do we sanitize URLs before parsing?
- [ ] Could malformed URLs crash the parser?
- [ ] Do we handle javascript: and data: URLs safely?

**External Content**:
- [ ] Are URL card previews loaded securely (HTTPS)?
- [ ] Do we validate image content from URL previews?
- [ ] Could malicious URL cards exploit vulnerabilities?
- [ ] Do we have CSP-equivalent protections?

### 8.2 Privacy Considerations

**Network Requests**:
- [ ] Do we leak user's post content when loading URL cards?
- [ ] Are URL card requests sent directly or through proxy?
- [ ] Do we cache URL cards (could leak browsing history)?
- [ ] Are analytics/tracking pixels blocked?

**User Data**:
- [ ] Are draft posts with URLs encrypted?
- [ ] Are URL cards persisted securely?
- [ ] Could URL history reveal sensitive information?
- [ ] Do we comply with privacy regulations?

---

## Section 9: Deployment Considerations

### 9.1 Rollout Strategy

**Feature Flags**:
- [ ] Should Phase 1 fixes be behind a feature flag?
- [ ] Can we enable fixes incrementally (fix 1, then 2, etc.)?
- [ ] What's the rollback plan if issues arise?
- [ ] How quickly can we disable features remotely?

**Monitoring**:
- [ ] What metrics should we track post-deployment?
- [ ] How do we measure success of fixes?
- [ ] What crash patterns should we watch for?
- [ ] User feedback channels established?

### 9.2 Migration Path

**Backward Compatibility**:
- [ ] Do changes break existing drafts?
- [ ] Can old clients read new state format?
- [ ] Is there a migration path for persisted state?
- [ ] What happens when user has old app version?

**Versioning**:
- [ ] Should we version the URL state format?
- [ ] How do we handle cross-version synchronization?
- [ ] What's the deprecation timeline for old formats?

---

## Section 10: Open Questions & Action Items

### Critical Unresolved Questions

1. **Should manual text deletion keep or remove the URL card?**
   - Get user research data
   - A/B test different behaviors
   - Document final decision and rationale

2. **Is disabling UITextView data detectors safe?**
   - Comprehensive URL detection testing
   - Compare PostParser vs UIKit on real-world data
   - Identify any URLs we'd miss

3. **What's the right granularity for sticky cards?**
   - Card per URL? Card per embed? Single card per post?
   - How do we handle multiple URLs elegantly?
   - UX mock-ups needed

4. **Should we refactor to unified state model now or later?**
   - Estimate effort vs benefit
   - Risk analysis of major refactor
   - Incremental migration possible?

5. **How do we handle URL cards in threads?**
   - Independent cards per thread entry?
   - Shared card state?
   - Different UX for threads?

### Action Items for Parallel Agents

- [ ] **Agent 1**: Deep dive into PostParser URL detection coverage
- [ ] **Agent 2**: Analyze UIKit vs SwiftUI text handling differences
- [ ] **Agent 3**: Review thread mode state management
- [ ] **Agent 4**: Performance profiling and optimization opportunities
- [ ] **Agent 5**: Security audit of URL handling
- [ ] **Agent 6**: Accessibility compliance review
- [ ] **Agent 7**: User research on URL card behavior expectations
- [ ] **Agent 8**: Code quality and maintainability assessment

---

## Appendix: Related Resources

**Code Files**:
- Primary: `PostComposerViewModel.swift`, `PostComposerTextProcessing.swift`, `PostComposerCore.swift`
- Secondary: `PostParser.swift`, `RichTextEditor.swift`, `ComposeURLCardView.swift`
- State: `PostComposerModels.swift`, `LinkStatePersistence.swift`

**Documentation**:
- `POST_COMPOSER_URL_BEHAVIOR_ANALYSIS.md` - Problem analysis
- `POST_COMPOSER_PHASE1_FIXES.md` - Implementation guide
- `POST_COMPOSER_LINK_FIXES.md` - Original feature spec
- `POST_COMPOSER_LINK_FIXES_BUG_AND_FIX.md` - Bug fix documentation

**External References**:
- AT Protocol URL embed specification
- UITextView documentation on typing attributes
- NSDataDetector documentation
- Swift 6 concurrency model documentation

---

## Completion Checklist

- [ ] All sections reviewed by at least one agent
- [ ] Critical questions answered or marked for research
- [ ] Consensus reached on Phase 1 implementation
- [ ] Testing strategy approved
- [ ] Rollout plan documented
- [ ] Monitoring strategy in place
- [ ] Phase 2 planning initiated based on findings
