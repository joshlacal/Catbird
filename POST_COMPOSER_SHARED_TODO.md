# 📋 Post Composer URL Handling - Shared TODO List

**Last Updated**: December 2024  
**Status**: Active Development  
**Coordination**: All agents/developers update this file

---

## 📊 Progress Overview

| Phase | Total Tasks | Completed | In Progress | Blocked | Not Started |
|-------|-------------|-----------|-------------|---------|-------------|
| Analysis | 1 | 1 ✅ | 0 | 0 | 0 |
| Documentation | 4 | 4 ✅ | 0 | 0 | 0 |
| Implementation | 4 | 0 | 0 | 0 | 4 ⏳ |
| Testing | 8 | 0 | 0 | 0 | 8 ⏳ |
| Review | 10 | 0 | 0 | 0 | 10 ⏳ |
| Deployment | 5 | 0 | 0 | 0 | 5 ⏳ |
| **TOTAL** | **32** | **5** | **0** | **0** | **27** |

**Overall Progress**: 16% (5/32 tasks complete)

---

## 🚀 Phase 1: Critical Implementation Tasks

### IMPL-001: Clear Manual Link Facets ⏳
**Priority**: 🔴 Critical  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Description**: Modify `removeURLFromText()` to clear `manualLinkFacets` that reference the removed URL

**Acceptance Criteria**:
- [ ] Add facet filtering logic in `removeURLFromText()`
- [ ] Filter by matching URL in link facets
- [ ] Handle case where facet has multiple features
- [ ] Add logging for debugging
- [ ] Verify no blue text after URL removal

**Files to Modify**:
- `Catbird/Features/Feed/Views/Components/PostComposer/PostComposerCore.swift`

**Code Location**: `func removeURLFromText(for url: String)` around line 135

**Dependencies**: None

**Testing**:
- Manual test: Paste URL, click "Remove link from text", type new text
- Expected: New text is normal color

**Notes**:
```swift
// Add after line 151 (before updatePostContent() call)
manualLinkFacets.removeAll { facet in
    facet.features.contains { feature in
        if case .appBskyRichtextFacetLink(let link) = feature {
            return link.uri.uriString() == url
        }
        return false
    }
}
```

---

### IMPL-002: Reset Typing Attributes ⏳
**Priority**: 🔴 Critical  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Description**: Add mechanism to reset UITextView typing attributes after URL removal

**Acceptance Criteria**:
- [ ] Add `activeRichTextView: RichTextView?` weak reference to ViewModel
- [ ] Create `resetTypingAttributes()` helper method
- [ ] Call helper after removing URL text
- [ ] Wire up reference in UIKit bridge
- [ ] Verify typing attributes are reset

**Files to Modify**:
- `Catbird/Features/Feed/Views/Components/PostComposer/PostComposerViewModel.swift`
- `Catbird/Features/Feed/Views/Components/PostComposer/PostComposerCore.swift`
- `Catbird/Features/Feed/Views/Components/PostComposer/PostComposerViewUIKit.swift`

**Dependencies**: IMPL-001

**Testing**:
- Manual test: Remove URL, type new text
- Expected: Text has default font and color

**Notes**:
- Use `#if os(iOS)` for platform-specific code
- Reset to `.font` and `.foregroundColor` only
- Don't interfere with other text attributes

---

### IMPL-003: Disable Data Detectors ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 30 minutes  
**Status**: Not Started

**Description**: Change `dataDetectorTypes` from `.all` to `[]` in RichTextView

**Acceptance Criteria**:
- [ ] Change `dataDetectorTypes = []` in setupView()
- [ ] Verify URLs still detected by PostParser
- [ ] Test that link styling still works
- [ ] Confirm no automatic phone/address detection
- [ ] Document the change in code comments

**Files to Modify**:
- `Catbird/Features/Feed/Views/Components/PostComposer/RichTextEditor.swift`

**Code Location**: `private func setupView()` around line 30

**Dependencies**: None (can be done independently)

**Testing**:
- Paste various URLs, verify all detected
- Paste phone number, verify NOT auto-detected
- Check that manual facet system works

**Notes**:
- This is iOS-only (macOS uses NSTextView)
- Add comment explaining why we disable auto-detection
- Consider as optional if concerns arise

---

### IMPL-004: Clear Facets on Manual Deletion ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 3 hours  
**Status**: Not Started

**Description**: Track removed URLs and clear their facets in `handleDetectedURLsOptimized()`

**Acceptance Criteria**:
- [ ] Track previous URLs vs current URLs
- [ ] Calculate removed URLs (set subtraction)
- [ ] Clear `manualLinkFacets` for removed URLs
- [ ] Reset typing attributes if facets removed
- [ ] Add debug logging

**Files to Modify**:
- `Catbird/Features/Feed/Views/Components/PostComposer/PostComposerTextProcessing.swift`

**Code Location**: `private func handleDetectedURLsOptimized(_ urls: [String])` around line 227

**Dependencies**: IMPL-002 (needs resetTypingAttributes method)

**Testing**:
- Manually delete URL (not via button)
- Verify card disappears
- Verify no blue text remains
- Type new text, verify normal color

**Notes**:
- Need access to `activeRichTextView` reference
- Performance: Set operations should be fast
- Consider debouncing if needed

---

## 🧪 Phase 2: Testing Tasks

### TEST-001: Unit Test - Facet Clearing ⏳
**Priority**: 🔴 Critical  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Description**: Write unit tests for manual link facet clearing logic

**Test Cases**:
- [ ] Clear facets for single URL
- [ ] Clear facets for specific URL when multiple exist
- [ ] Handle facets with multiple features
- [ ] Handle empty `manualLinkFacets`
- [ ] Handle URL not in facets

**Files to Modify**:
- `CatbirdTests/CatbirdTests.swift` or create new test file

**Dependencies**: IMPL-001

**Framework**: Swift Testing (use `@Test` attribute, NOT XCTest)

---

### TEST-002: Unit Test - Typing Attributes Reset ⏳
**Priority**: 🔴 Critical  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 1 hour  
**Status**: Not Started

**Description**: Test that typing attributes are properly reset

**Test Cases**:
- [ ] Attributes reset after URL removal
- [ ] Correct default attributes applied
- [ ] Weak reference handled correctly
- [ ] iOS-specific code doesn't break macOS

**Dependencies**: IMPL-002

---

### TEST-003: Integration Test - Remove URL via Button ⏳
**Priority**: 🔴 Critical  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 1 hour  
**Status**: Not Started

**Description**: End-to-end test of "Remove link from text" button flow

**Test Cases**:
- [ ] Paste URL → Button appears
- [ ] Click button → URL text removed
- [ ] Card stays visible with "Featured" badge
- [ ] Type new text → Normal styling
- [ ] Post created → Embed present, no facet

**Dependencies**: IMPL-001, IMPL-002

**Platform**: iOS 18+ simulator

---

### TEST-004: Integration Test - Manual URL Deletion ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 1 hour  
**Status**: Not Started

**Description**: Test manual deletion behavior

**Test Cases**:
- [ ] Paste URL → Manually delete
- [ ] Card disappears (expected)
- [ ] No blue text remains
- [ ] Type new text → Normal styling
- [ ] No phantom facets in post

**Dependencies**: IMPL-004

---

### TEST-005: Integration Test - Multiple URLs ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 1.5 hours  
**Status**: Not Started

**Description**: Test behavior with multiple URLs in post

**Test Cases**:
- [ ] Paste 3 URLs → First gets card
- [ ] All URLs are blue
- [ ] Remove first URL via button
- [ ] Card stays, first URL facet removed
- [ ] Other URLs still blue and clickable
- [ ] Post created → First URL embedded, others as facets

**Dependencies**: IMPL-001, IMPL-002

---

### TEST-006: Integration Test - Thread Mode ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Description**: Verify URL handling in thread mode

**Test Cases**:
- [ ] Create thread with 3 entries
- [ ] Add URL to entry 1, remove text via button
- [ ] Switch to entry 2
- [ ] Switch back to entry 1
- [ ] Verify card still visible
- [ ] Post thread → Entry 1 has embed

**Dependencies**: IMPL-001, IMPL-002

---

### TEST-007: Platform Test - macOS Compatibility ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Description**: Verify all fixes work on macOS

**Test Cases**:
- [ ] All iOS tests repeated on macOS
- [ ] NSTextView behaves correctly
- [ ] Typing attributes handled properly
- [ ] No platform-specific crashes

**Dependencies**: All IMPL tasks

**Platform**: macOS 13+

---

### TEST-008: Regression Test - Existing Functionality ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Description**: Ensure we didn't break anything

**Test Cases**:
- [ ] Normal posting (no URLs)
- [ ] Posting with URL (no removal)
- [ ] Mentions still work
- [ ] Hashtags still work
- [ ] Media attachment works
- [ ] GIF attachment works
- [ ] Reply threads work
- [ ] Quote posts work

**Dependencies**: All IMPL tasks

---

## 🔍 Phase 3: Code Review Tasks

### REVIEW-001: State Management Review ⏳
**Priority**: 🔴 Critical  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Description**: Review state variable usage and synchronization

**Focus Areas**:
- [ ] `detectedURLs`, `urlCards`, `selectedEmbedURL` consistency
- [ ] `urlsKeptForEmbed` usage correct
- [ ] `manualLinkFacets` clearing comprehensive
- [ ] Thread entry state persistence complete
- [ ] No state divergence possible

**Dependencies**: All IMPL tasks

**Reference**: `POST_COMPOSER_SCRUTINY_CHECKLIST.md` Section 1.1

---

### REVIEW-002: Text Processing Pipeline Review ⏳
**Priority**: 🔴 Critical  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Description**: Trace text update flow end-to-end

**Focus Areas**:
- [ ] No circular dependencies
- [ ] No infinite loop risks
- [ ] Proper debouncing/throttling
- [ ] Facet byte ranges always valid
- [ ] Performance acceptable

**Reference**: `POST_COMPOSER_SCRUTINY_CHECKLIST.md` Section 1.2

---

### REVIEW-003: UIKit Integration Review ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 1.5 hours  
**Status**: Not Started

**Description**: Review UITextView integration and behavior

**Focus Areas**:
- [ ] Weak reference management safe
- [ ] Typing attributes handled correctly
- [ ] Data detectors change implications
- [ ] UIViewRepresentable updates correct

**Reference**: `POST_COMPOSER_SCRUTINY_CHECKLIST.md` Section 1.3

---

### REVIEW-004: Concurrency & Thread Safety ⏳
**Priority**: 🔴 Critical  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Description**: Verify Swift 6 concurrency compliance

**Focus Areas**:
- [ ] All `@MainActor` annotations correct
- [ ] No data races possible
- [ ] Async/await usage correct
- [ ] Sendable constraints satisfied
- [ ] Actor isolation proper

**Reference**: `POST_COMPOSER_SCRUTINY_CHECKLIST.md` Section 1.1.C

---

### REVIEW-005: Edge Cases & Error Handling ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Description**: Identify and verify edge case handling

**Focus Areas**:
- [ ] Same URL appears twice in text
- [ ] Extremely long URLs (10KB+)
- [ ] Invalid/malformed URLs
- [ ] URL card loading failures
- [ ] Network timeout scenarios
- [ ] Race conditions

**Reference**: `POST_COMPOSER_SCRUTINY_CHECKLIST.md` Section 2

---

### REVIEW-006: Performance Analysis ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Description**: Profile performance impact of changes

**Focus Areas**:
- [ ] Text update latency < 16ms
- [ ] Facet generation performance
- [ ] Memory usage acceptable
- [ ] No unnecessary attributed string copies
- [ ] Debouncing effective

**Reference**: `POST_COMPOSER_SCRUTINY_CHECKLIST.md` Section 6

---

### REVIEW-007: Accessibility Audit ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 1.5 hours  
**Status**: Not Started

**Description**: Verify accessibility compliance

**Focus Areas**:
- [ ] Screen reader announces correctly
- [ ] Keyboard navigation works
- [ ] Sufficient color contrast
- [ ] Reduce Motion supported
- [ ] Dynamic Type supported

**Reference**: `POST_COMPOSER_SCRUTINY_CHECKLIST.md` Section 5.3

---

### REVIEW-008: Security Review ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 1 hour  
**Status**: Not Started

**Description**: Security audit of URL handling

**Focus Areas**:
- [ ] No URL injection vulnerabilities
- [ ] javascript: URLs handled safely
- [ ] data: URLs handled safely
- [ ] No XSS-equivalent issues
- [ ] URL sanitization appropriate

**Reference**: `POST_COMPOSER_SCRUTINY_CHECKLIST.md` Section 8

---

### REVIEW-009: Code Quality Assessment ⏳
**Priority**: 🟡 Medium  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 1 hour  
**Status**: Not Started

**Description**: General code quality review

**Focus Areas**:
- [ ] Clear variable names
- [ ] Appropriate comments
- [ ] No overly complex functions
- [ ] Error handling comprehensive
- [ ] Follows Swift style guide

**Reference**: `POST_COMPOSER_SCRUTINY_CHECKLIST.md` Section 7

---

### REVIEW-010: Documentation Review ⏳
**Priority**: 🟡 Medium  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 1 hour  
**Status**: Not Started

**Description**: Ensure documentation is complete and accurate

**Focus Areas**:
- [ ] All code changes documented
- [ ] Public APIs have doc comments
- [ ] Complex logic explained
- [ ] Edge cases noted
- [ ] Architecture decisions recorded

---

## 🤖 Phase 4: AI Agent Deep Dive Tasks

### AGENT-001: URL Detection Coverage Analysis ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 3 hours  
**Status**: Not Started

**Description**: Compare PostParser URL detection vs UIKit NSDataDetector

**Deliverables**:
- [ ] List of URL formats tested (100+ samples)
- [ ] Detection accuracy comparison
- [ ] False positives/negatives identified
- [ ] Recommendations for improvement
- [ ] Risk assessment of disabling data detectors

**Output**: Document findings in `POST_COMPOSER_URL_DETECTION_ANALYSIS.md`

---

### AGENT-002: UIKit vs SwiftUI Behavior Analysis ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 3 hours  
**Status**: Not Started

**Description**: Deep dive into text view behavior differences

**Deliverables**:
- [ ] UITextView typing attribute behavior documented
- [ ] SwiftUI TextField behavior documented
- [ ] Platform differences identified
- [ ] Workarounds for inconsistencies
- [ ] Best practices recommendations

**Output**: Add section to analysis document

---

### AGENT-003: Performance Profiling ⏳
**Priority**: 🟡 Medium  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 4 hours  
**Status**: Not Started

**Description**: Profile current and proposed implementation

**Deliverables**:
- [ ] Baseline performance metrics
- [ ] Performance with changes
- [ ] Bottlenecks identified
- [ ] Optimization opportunities
- [ ] Acceptable thresholds defined

**Tools**: Instruments, Time Profiler, Allocations

---

### AGENT-004: Thread Mode State Analysis ⏳
**Priority**: 🟡 Medium  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 3 hours  
**Status**: Not Started

**Description**: Analyze thread entry state management

**Deliverables**:
- [ ] State flow diagram
- [ ] Synchronization points identified
- [ ] Potential race conditions
- [ ] Improvement recommendations
- [ ] Test case suggestions

---

### AGENT-005: Security Audit ⏳
**Priority**: 🟡 Medium  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 3 hours  
**Status**: Not Started

**Description**: Comprehensive security review of URL handling

**Deliverables**:
- [ ] Threat model
- [ ] Vulnerability assessment
- [ ] Attack scenarios
- [ ] Mitigation strategies
- [ ] Security best practices

---

### AGENT-006: Accessibility Compliance Review ⏳
**Priority**: 🟡 Medium  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Description**: Full accessibility audit

**Deliverables**:
- [ ] WCAG compliance checklist
- [ ] VoiceOver testing results
- [ ] Keyboard navigation assessment
- [ ] Color contrast verification
- [ ] Improvement recommendations

---

### AGENT-007: User Experience Research ⏳
**Priority**: 🟡 Medium  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 3 hours  
**Status**: Not Started

**Description**: Research user expectations and patterns

**Deliverables**:
- [ ] Survey of other social media apps
- [ ] User mental model analysis
- [ ] Behavior expectations documented
- [ ] UX improvement suggestions
- [ ] A/B test recommendations

---

### AGENT-008: Architecture Design Validation ⏳
**Priority**: 🟡 Medium  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 4 hours  
**Status**: Not Started

**Description**: Critique proposed architectural changes

**Deliverables**:
- [ ] Sticky cards design evaluation
- [ ] Unified state model evaluation
- [ ] Alternative approaches
- [ ] Migration strategy
- [ ] Risk assessment

---

## 🚀 Phase 5: Deployment Tasks

### DEPLOY-001: Pre-deployment Checklist ⏳
**Priority**: 🔴 Critical  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 1 hour  
**Status**: Not Started

**Checklist**:
- [ ] All implementation tasks complete
- [ ] All tests passing
- [ ] Code review approved
- [ ] Performance acceptable
- [ ] No new warnings/errors
- [ ] Documentation updated
- [ ] Release notes written

---

### DEPLOY-002: TestFlight Beta Release ⏳
**Priority**: 🔴 Critical  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Steps**:
- [ ] Create release build
- [ ] Upload to TestFlight
- [ ] Invite beta testers
- [ ] Provide testing instructions
- [ ] Monitor crash reports
- [ ] Collect feedback

---

### DEPLOY-003: Monitoring Setup ⏳
**Priority**: 🟡 High  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 2 hours  
**Status**: Not Started

**Metrics to Track**:
- [ ] Crash rate (URL handling related)
- [ ] Performance metrics
- [ ] User feedback sentiment
- [ ] Bug report frequency
- [ ] Usage patterns

---

### DEPLOY-004: Production Deployment ⏳
**Priority**: 🔴 Critical  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: 1 hour  
**Status**: Not Started

**Steps**:
- [ ] Final testing complete
- [ ] Beta feedback reviewed
- [ ] Release notes finalized
- [ ] App Store submission
- [ ] Staged rollout plan

---

### DEPLOY-005: Post-deployment Monitor ⏳
**Priority**: 🔴 Critical  
**Owner**: `[UNCLAIMED]`  
**Estimated Time**: Ongoing (first week)  
**Status**: Not Started

**Activities**:
- [ ] Monitor crash reports daily
- [ ] Track key metrics
- [ ] Respond to user feedback
- [ ] Quick-fix any critical bugs
- [ ] Document lessons learned

---

## 🐛 Issues Found During Implementation

**Instructions**: Add any bugs or issues you discover here

### Issue Template
```
### ISSUE-XXX: [Short Description]
**Severity**: Critical/High/Medium/Low
**Discovered By**: [Name]
**Date**: [Date]
**Description**: [Detailed description]
**Steps to Reproduce**: 
1. 
2. 
3. 
**Expected Behavior**: 
**Actual Behavior**: 
**Proposed Fix**: 
**Status**: Open/In Progress/Fixed
```

---

## ❓ Open Questions

**Instructions**: Add questions that need answering here

### Question Template
```
### Q-XXX: [Question]
**Asked By**: [Name]
**Date**: [Date]
**Context**: [Background info]
**Options Considered**:
- Option A: ...
- Option B: ...
**Decision Needed By**: [Date/Milestone]
**Answer**: [To be filled in]
**Decided By**: [Name]
```

---

## 💡 Improvement Ideas

**Instructions**: Add enhancement ideas for future phases

### Idea Template
```
### IDEA-XXX: [Title]
**Proposed By**: [Name]
**Date**: [Date]
**Description**: [What and why]
**Benefits**: [Expected improvements]
**Effort**: Small/Medium/Large
**Priority**: For consideration
```

---

## 📝 Notes & Learnings

**Instructions**: Document insights, gotchas, and lessons learned

### Note Template
```
### NOTE-XXX: [Title]
**Date**: [Date]
**Author**: [Name]
**Category**: Implementation/Testing/Review/General
**Content**: [The insight or learning]
```

---

## 🔄 Status Update Log

**Instructions**: Log significant progress updates

### 2024-12-XX - Initial Setup
- Documentation created
- TODO list established
- Ready for implementation to begin

---

## 📊 Metrics & KPIs

### Code Quality Metrics
- [ ] Swift warnings: 0
- [ ] Swift errors: 0
- [ ] SwiftLint violations: < 5
- [ ] Code coverage: > 80%
- [ ] Cyclomatic complexity: < 10 per function

### Performance Metrics
- [ ] Text update latency: < 16ms (60fps)
- [ ] URL card loading: < 500ms perceived
- [ ] Memory usage: < 10MB additional
- [ ] CPU usage: < 5% during typing

### User Experience Metrics
- [ ] Crash-free sessions: > 99.9%
- [ ] User-reported bugs: < 5 per week
- [ ] Feature satisfaction: > 4/5 stars
- [ ] Task completion rate: > 95%

---

## 🎯 Definition of Done

A task is considered "Done" when:

### For Implementation Tasks
✅ Code written and compiles without errors  
✅ Unit tests written and passing  
✅ Integration tests passing  
✅ Code reviewed and approved  
✅ Documentation updated  
✅ Manual testing completed  
✅ No regressions introduced  

### For Testing Tasks
✅ Test cases executed  
✅ Results documented  
✅ Bugs filed if found  
✅ Pass/fail clearly indicated  
✅ Edge cases covered  
✅ Both platforms tested (where applicable)  

### For Review Tasks
✅ Checklist items completed  
✅ Findings documented  
✅ Concerns raised with team  
✅ Recommendations provided  
✅ Approval or rejection given  

### For Deployment Tasks
✅ Pre-flight checklist passed  
✅ No critical bugs outstanding  
✅ Metrics being tracked  
✅ Team informed of status  
✅ Rollback plan ready  

---

## 🤝 Collaboration Guidelines

### Claiming Tasks
1. Add your name to **Owner** field
2. Update **Status** to "In Progress"
3. Add **Start Date**
4. Notify team if needed

### Updating Progress
1. Update status regularly (daily if possible)
2. Add notes about blockers or issues
3. Link related tasks if dependencies discovered
4. Ask for help if stuck > 2 hours

### Completing Tasks
1. Check all acceptance criteria
2. Update **Status** to "Complete"
3. Add **Completion Date**
4. Document any follow-up items
5. Update progress overview at top

### Communication
- Use this document as single source of truth
- Add questions/issues in dedicated sections
- Reference task IDs in commits: "IMPL-001: Clear manual link facets"
- Update regularly to avoid conflicts

---

## 📞 Emergency Contacts

### Blockers
If completely blocked and need help immediately, check:
1. Documentation in `POST_COMPOSER_*.md` files
2. Code comments in related files
3. Git history for context
4. Add question to "Open Questions" section

### Critical Bugs
If you discover a critical bug:
1. Add to "Issues Found" section immediately
2. Mark severity as Critical
3. Notify team
4. Consider if deployment should be blocked

---

*This TODO list is a living document. Update it frequently and keep it accurate!*

