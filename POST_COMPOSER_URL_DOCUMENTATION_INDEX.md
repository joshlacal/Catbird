# Post Composer URL Handling - Documentation Index

## Overview

This document serves as the entry point for understanding and improving the post composer's URL handling system. It provides a roadmap through the analysis, proposed solutions, and scrutiny framework.

---

## Current Status

### Issues Identified
1. ✅ **Phantom blue text highlighting** - After removing URL, new text appears as links
2. ✅ **Facet contamination** - Stale link facets persist after URL removal  
3. ✅ **Inconsistent card behavior** - Manual deletion vs button deletion behave differently
4. ⚠️ **UITextView interference** - Data detectors conflict with manual facet system
5. ⚠️ **Complex state management** - Multiple overlapping state variables create bugs

### What Works
- ✅ URL detection in text
- ✅ URL card loading and display
- ✅ First URL selected as embed
- ✅ State persistence in thread entries
- ✅ Basic "Remove link from text" button functionality

### What Needs Fixing
- ❌ Blue text after URL removal
- ❌ Stale facets causing wrong links
- ❌ Confusing user experience
- ❌ Fragile state management
- ❌ Thread entry state synchronization issues

---

## Documentation Structure

### 1. Problem Analysis
**File**: `POST_COMPOSER_URL_BEHAVIOR_ANALYSIS.md`

**Purpose**: Comprehensive analysis of current behavior, root causes, and architectural issues

**Key Sections**:
- Current behavior scenarios (manual deletion, button deletion, multiple URLs)
- Root cause analysis (reactive vs sticky, facet contamination, state separation)
- Proposed solutions (sticky lifecycle, clear facets, disable data detectors, unified state)
- Implementation phases
- Questions for review

**Read this first** to understand the full scope of the problem.

### 2. Implementation Guide
**File**: `POST_COMPOSER_PHASE1_FIXES.md`

**Purpose**: Step-by-step implementation guide for critical fixes

**Key Sections**:
- Fix 1: Clear manual link facets when removing URL text
- Fix 2: Reset typing attributes in RichTextView
- Fix 3: Disable UITextView data detectors (optional but recommended)
- Fix 4: Clear facets on manual text deletion
- Implementation checklist
- Testing requirements
- Risk assessment

**Read this second** to understand how to implement the fixes.

### 3. Scrutiny Framework
**File**: `POST_COMPOSER_SCRUTINY_CHECKLIST.md`

**Purpose**: Structured framework for parallel agents to critique and validate solutions

**Key Sections**:
- Current implementation analysis (state management, text processing, UIKit integration)
- Proposed solution validation (each fix critiqued individually)
- Architectural concerns (sticky cards, unified state)
- Testing strategy (unit, integration, UI tests)
- User experience evaluation
- Performance & scalability
- Code quality review
- Security & privacy
- Open questions and action items

**Use this third** to systematically review and validate the approach.

### 4. Historical Context
**File**: `POST_COMPOSER_LINK_FIXES.md`

**Purpose**: Original feature specification for URL link handling

**Covers**:
- Initial implementation of multiple link handling
- First attempt at "Remove link from text" feature
- Original behavior changes

**Read for context** on how we got here.

### 5. Bug Report
**File**: `POST_COMPOSER_LINK_FIXES_BUG_AND_FIX.md`

**Purpose**: Documentation of bugs found in original implementation

**Covers**:
- Bug 1: URL cards cleared on text update
- Bug 2: State not persisted in ThreadEntry
- Initial fix with `urlsKeptForEmbed` set
- Thread entry persistence updates

**Read for context** on first round of bug fixes.

---

## Quick Start Guide

### For Implementers

1. **Read** `POST_COMPOSER_URL_BEHAVIOR_ANALYSIS.md` (15 min)
   - Understand the problems and proposed solutions
   
2. **Read** `POST_COMPOSER_PHASE1_FIXES.md` (10 min)
   - Get implementation details for critical fixes
   
3. **Implement** fixes in order (2-4 hours)
   - Fix 1: Clear manual link facets
   - Fix 2: Reset typing attributes  
   - Fix 3: Disable data detectors
   - Fix 4: Clear facets on manual deletion
   
4. **Test** thoroughly (2-3 hours)
   - Run all test cases from Phase 1 doc
   - Test on both iOS and macOS
   - Test in thread mode
   
5. **Get code review** from another developer
   - Use scrutiny checklist for thorough review

### For Reviewers

1. **Read** `POST_COMPOSER_SCRUTINY_CHECKLIST.md` (20 min)
   - Understand the review framework
   
2. **Review code** against checklist (1-2 hours)
   - Go through each section systematically
   - Document findings and concerns
   
3. **Test** the implementation (1 hour)
   - Run through critical user flows
   - Try to break it with edge cases
   
4. **Provide feedback** with specific references to:
   - Which checklist items passed/failed
   - Specific concerns or alternative approaches
   - Additional test cases needed

### For Parallel Agents

1. **Read** all documentation (1 hour)
   - Get full context of the system
   
2. **Choose focus area** from Section 10 action items in scrutiny checklist
   - Each agent takes a different area
   
3. **Deep dive** into assigned area (2-3 hours)
   - Research thoroughly
   - Document findings
   
4. **Report back** with:
   - Answers to open questions
   - Additional concerns discovered
   - Recommendations for improvements

---

## Key Concepts

### URL States
The system tracks URLs in multiple overlapping ways:
- **detectedURLs**: URLs found by parser in current text
- **urlCards**: Loaded card preview data
- **selectedEmbedURL**: Which URL will be used as embed
- **urlsKeptForEmbed**: URLs to keep even when removed from text
- **manualLinkFacets**: Link facets created by UIKit

### Facets
AT Protocol representation of rich text:
- **Link facets**: Make text clickable in posted version
- **Mention facets**: Tag users (@handle)
- **Tag facets**: Hashtags (#topic)
- Defined by byte ranges in UTF-8 text

### URL Cards
Rich preview cards for links:
- Loaded asynchronously from URL metadata
- Show title, description, thumbnail image
- One card can be selected as "embed" for post
- AT Protocol supports one external embed per post

### Two-Layer System
1. **Text Layer**: Facets for inline links (clickable)
2. **Embed Layer**: URL card for rich preview (one per post)

These are independent but often confused!

---

## Common Pitfalls

### ❌ Don't: Assume text and cards are synchronized
URL cards persist independently of text content.

### ✅ Do: Treat cards as separate attachments
Cards are like media items - explicit lifecycle management.

### ❌ Don't: Modify state during text processing
This creates race conditions and stale state.

### ✅ Do: Use debouncing for text-triggered updates
Give users time to finish typing before processing.

### ❌ Don't: Rely on UITextView's automatic behaviors
Data detectors interfere with manual facet management.

### ✅ Do: Implement explicit facet management
Full control over what's a link and what isn't.

### ❌ Don't: Share state between thread entries implicitly
Each entry needs its own complete state.

### ✅ Do: Explicitly save/restore all state variables
Include `selectedEmbedURL` and `urlsKeptForEmbed` in ThreadEntry.

---

## Architecture Principles

### 1. Explicit Over Implicit
Make all state transitions explicit and observable.

### 2. User Intent Over Automation
Let user actions drive behavior, not automatic parsing.

### 3. Single Source of Truth
Each piece of state should have one canonical source.

### 4. Independence of Layers
Text processing and embed management should be decoupled.

### 5. Fail Safe, Not Silent
If something goes wrong, make it obvious rather than hiding it.

---

## Testing Philosophy

### Unit Tests
- Test state transitions in isolation
- Mock external dependencies (URL card loading)
- Focus on edge cases and error conditions

### Integration Tests
- Test complete user flows end-to-end
- Verify state persistence across sessions
- Test thread mode thoroughly

### UI Tests  
- Automate critical user journeys
- Visual verification where possible
- Cover both iOS and macOS

### Manual QA
- Exploratory testing to find unexpected behaviors
- Accessibility testing with assistive technologies
- Performance testing with stress scenarios

---

## Success Metrics

### User Experience
- No confusing blue text after URL removal
- Predictable card behavior
- Clear visual feedback for all states
- Smooth, responsive typing

### Technical Quality
- Zero crashes related to URL handling
- No memory leaks or performance degradation
- Clean, maintainable code
- Comprehensive test coverage

### Feature Completeness
- All URL types detected correctly
- Cards load reliably
- Thread mode works correctly
- State persists across app lifecycle

---

## Future Enhancements

### Phase 2: Architectural Improvements
- Implement sticky URL card lifecycle
- Separate facet generation from embed management
- Better visual design for URL states
- User control over which URL to embed

### Phase 3: Advanced Features
- Multiple embeds per post (if AT Protocol adds support)
- URL shortening/expansion options
- Link preview customization
- Bulk URL operations

### Phase 4: Polish
- Animations for card appearance/removal
- Better loading states
- Improved error messages
- Enhanced accessibility

---

## Getting Help

### Questions About Code
- Review `POST_COMPOSER_URL_BEHAVIOR_ANALYSIS.md` for architecture
- Check `POST_COMPOSER_PHASE1_FIXES.md` for implementation details
- Look at code comments in modified files

### Questions About Testing
- See test cases in `POST_COMPOSER_PHASE1_FIXES.md`
- Review scrutiny checklist testing section
- Check existing test files for patterns

### Questions About UX
- Review user scenarios in analysis document
- Consider AT Protocol best practices
- Look at how other clients handle URLs

### Questions About Deployment
- See rollout strategy in scrutiny checklist
- Review risk assessment in Phase 1 doc
- Consider feature flag approach

---

## Changelog

### December 2024
- Initial analysis document created
- Phase 1 fixes documented
- Scrutiny framework established
- Bug fixes for state persistence implemented
- Documentation index created

---

## Related Resources

### Internal Documentation
- `CLAUDE.md` - Project overview and development guide
- `POST_COMPOSER_ARCHITECTURE.md` - Overall composer architecture
- `TESTING_COOKBOOK.md` - Testing patterns and practices

### External References
- [AT Protocol Specification](https://atproto.com/specs/at-uri-scheme)
- [RichText Facets Spec](https://atproto.com/specs/lexicon#rich-text-facets)
- [UITextView Documentation](https://developer.apple.com/documentation/uikit/uitextview)
- [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)

---

## Contributors

### Primary Authors
- Initial implementation: Development team
- Bug fixes: Development team
- Documentation: Claude (AI Assistant)

### Reviewers
- To be assigned from parallel agents
- Code review team
- QA team
- UX team

---

## Document Status

| Document | Status | Last Updated | Owner |
|----------|--------|--------------|-------|
| Analysis | ✅ Complete | Dec 2024 | Claude |
| Phase 1 Fixes | ✅ Complete | Dec 2024 | Claude |
| Scrutiny Checklist | ✅ Complete | Dec 2024 | Claude |
| Implementation | 🔄 In Progress | TBD | Dev Team |
| Testing | ⏳ Pending | TBD | QA Team |
| Deployment | ⏳ Pending | TBD | DevOps |

---

## Next Steps

1. **Team Review** (1-2 days)
   - Share documentation with team
   - Discuss and refine proposed solutions
   - Assign implementation owner

2. **Implementation** (3-5 days)
   - Implement Phase 1 fixes
   - Write/update unit tests
   - Perform initial QA

3. **Code Review** (1-2 days)
   - Thorough review using scrutiny checklist
   - Address feedback
   - Final approval

4. **Testing** (2-3 days)
   - Comprehensive regression testing
   - Platform coverage (iOS, macOS)
   - Accessibility testing

5. **Deployment** (1-2 days)
   - TestFlight beta release
   - Monitor metrics and crash reports
   - Gather user feedback

6. **Iteration** (Ongoing)
   - Address any issues discovered
   - Plan Phase 2 improvements
   - Continuous refinement

---

*This document is the starting point for understanding and improving the post composer URL handling system. Read through the linked documents in the order suggested above for a complete picture.*
