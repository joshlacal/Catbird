# 🚀 START HERE: Post Composer URL Handling Fixes

## ⚡ Quick Overview

The post composer has a critical bug where **text appears blue/highlighted after removing URLs**, plus several architectural issues making URL cards behave unpredictably. This is your entry point to understand, fix, and improve the system.

---

## 🎯 The Core Problem (In 60 Seconds)

### What Users Experience
1. User pastes URL: `https://example.com`
2. URL card loads (good ✅)
3. User clicks "Remove link from text" button
4. URL text is removed (good ✅)
5. User types new text
6. **❌ NEW TEXT IS BLUE AND STYLED LIKE A LINK**

### Why This Happens
- `manualLinkFacets` contains stale link facets with invalid byte ranges
- UITextView's `typingAttributes` inherits link styling from deleted URL
- UIKit's `dataDetectorTypes = .all` interferes with manual facet management
- Multiple overlapping state variables create fragile synchronization

### The Fix (Phase 1)
1. Clear `manualLinkFacets` when removing URL text
2. Reset `typingAttributes` in UITextView
3. Disable automatic data detectors
4. Clean up facets on manual text deletion

**Estimated effort**: 4-6 hours implementation + 3-4 hours testing

---

## 📚 Documentation Structure

### Read First (Required)
1. **THIS FILE** - You are here! Quick start and orientation
2. **`POST_COMPOSER_SHARED_TODO.md`** - Shared task list for all agents
3. **`POST_COMPOSER_URL_BEHAVIOR_ANALYSIS.md`** - Full problem analysis (15 min read)
4. **`POST_COMPOSER_PHASE1_FIXES.md`** - Implementation guide (10 min read)

### Reference Material (As Needed)
5. **`POST_COMPOSER_SCRUTINY_CHECKLIST.md`** - Review framework for agents
6. **`POST_COMPOSER_URL_DOCUMENTATION_INDEX.md`** - Master index
7. **`POST_COMPOSER_LINK_FIXES_BUG_AND_FIX.md`** - Historical bug fixes
8. **`POST_COMPOSER_LINK_FIXES.md`** - Original feature spec

---

## 👥 Role-Based Quick Starts

### 🔨 If You're Implementing the Fix

**Time commitment**: 1 day (6-8 hours)

```
1. Read analysis doc        [15 min]
2. Read Phase 1 fixes doc   [10 min]
3. Check shared TODO        [5 min]
4. Claim tasks in TODO      [Update doc]
5. Implement fixes          [4-6 hours]
6. Run tests               [1-2 hours]
7. Mark TODO items done    [Update doc]
8. Request code review     [Create PR]
```

**Key files to modify**:
- `PostComposerCore.swift` - Add facet clearing + typing attribute reset
- `PostComposerTextProcessing.swift` - Track removed URLs + clear facets
- `RichTextEditor.swift` - Disable data detectors
- `PostComposerViewModel.swift` - Add reference to active RichTextView

**Start with**: Task ID: `IMPL-001` in shared TODO

---

### 🔍 If You're Reviewing the Code

**Time commitment**: 2-3 hours

```
1. Read analysis doc                [15 min]
2. Read scrutiny checklist          [20 min]
3. Check shared TODO                [5 min]
4. Claim review section             [Update doc]
5. Review code against checklist    [1-2 hours]
6. Document findings                [30 min]
7. Update TODO with findings        [Update doc]
```

**Focus areas**:
- State management correctness
- Thread safety (Swift 6 concurrency)
- Edge cases and error handling
- Performance implications

**Start with**: Task ID: `REVIEW-001` in shared TODO

---

### 🧪 If You're Testing

**Time commitment**: 3-4 hours

```
1. Read Phase 1 fixes doc      [10 min]
2. Read test scenarios         [10 min]
3. Check shared TODO           [5 min]
4. Claim test sections         [Update doc]
5. Run manual tests            [2-3 hours]
6. Document bugs found         [30 min]
7. Update TODO                 [Update doc]
```

**Test environments**:
- iOS 18+ simulator (iPhone 16 Pro)
- macOS 13+ (native)
- Thread mode
- Multiple URLs scenarios

**Start with**: Task ID: `TEST-001` in shared TODO

---

### 🤖 If You're a Parallel Agent (AI)

**Time commitment**: 2-4 hours per focus area

```
1. Read ALL documentation      [1 hour]
2. Check shared TODO           [5 min]
3. Claim analysis area         [Update doc]
4. Deep dive research          [2-3 hours]
5. Document findings           [30 min]
6. Answer open questions       [Update doc]
7. Update TODO                 [Update doc]
```

**Available focus areas**:
- URL detection coverage analysis
- UIKit vs SwiftUI behavior comparison
- Performance profiling
- Security audit
- Accessibility review
- Architecture design validation

**Start with**: Task ID: `AGENT-001` through `AGENT-008` in shared TODO

---

## 🎯 Critical Success Criteria

After fixes are complete, these MUST be true:

### User Experience
- [ ] No blue/highlighted text after removing URL via button
- [ ] New typed text has normal styling (black/white depending on theme)
- [ ] URL cards behave predictably (stay when expected, disappear when expected)
- [ ] No crashes or errors during URL handling

### Technical Quality
- [ ] All unit tests pass
- [ ] No Swift 6 concurrency warnings
- [ ] No memory leaks detected
- [ ] Performance acceptable (< 16ms per text update)

### Platform Coverage
- [ ] Works on iOS 18+ (iPhone)
- [ ] Works on macOS 13+ (native)
- [ ] Thread mode works correctly
- [ ] State persists across app restarts

---

## 🚨 Critical Files Reference

### State Management
```
PostComposerViewModel.swift
├─ detectedURLs: [String]
├─ urlCards: [String: URLCardResponse]
├─ selectedEmbedURL: String?
├─ urlsKeptForEmbed: Set<String>
├─ manualLinkFacets: [AppBskyRichtextFacet]  ⚠️ Problem source
└─ activeRichTextView: RichTextView?  ⚠️ Need to add
```

### Text Processing
```
PostComposerTextProcessing.swift
├─ updatePostContent()
├─ handleDetectedURLsOptimized()  ⚠️ Needs modification
└─ updateAttributedText()
```

### Core Logic
```
PostComposerCore.swift
├─ removeURLFromText(for:)  ⚠️ Needs modification
├─ removeURLCard(for:)
├─ willBeUsedAsEmbed(for:)
└─ resetTypingAttributes()  ⚠️ Need to add
```

### UI Layer
```
RichTextEditor.swift
├─ RichTextView class
└─ setupView()  ⚠️ dataDetectorTypes needs change
```

### State Persistence
```
PostComposerModels.swift
├─ ThreadEntry struct
└─ CodableThreadEntry struct
```

---

## 🔧 Development Environment Setup

### Prerequisites
```bash
# Check you're in the right directory
cd /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird

# Verify Swift version (should be 6.0+)
swift --version

# Build the project to ensure baseline works
./quick-build.sh Catbird
```

### Before You Start
1. Create a feature branch:
   ```bash
   git checkout -b fix/post-composer-url-handling
   ```

2. Verify baseline tests pass:
   ```bash
   # iOS tests
   # Use MCP: test_sim with simulatorName: "iPhone 16 Pro"
   
   # macOS tests
   # Use MCP: test_macos with scheme: "Catbird"
   ```

3. Read the key documentation (30 min investment saves hours later!)

---

## 🐛 Known Issues & Gotchas

### Issue 1: Manual Link Facets Persist
**Symptom**: Blue text after URL removal  
**Cause**: `manualLinkFacets` not cleared  
**Fix**: Clear facets in `removeURLFromText()`  
**Priority**: 🔴 Critical

### Issue 2: Typing Attributes Inheritance
**Symptom**: New text inherits link color  
**Cause**: UITextView preserves last character's attributes  
**Fix**: Reset `typingAttributes` after URL removal  
**Priority**: 🔴 Critical

### Issue 3: UIKit Data Detector Interference
**Symptom**: Unexpected link styling  
**Cause**: `dataDetectorTypes = .all` conflicts with manual facets  
**Fix**: Set `dataDetectorTypes = []`  
**Priority**: 🟡 High

### Issue 4: State Not Persisted in ThreadEntry
**Symptom**: URL cards disappear when switching thread entries  
**Cause**: `selectedEmbedURL` and `urlsKeptForEmbed` not saved  
**Fix**: Already implemented in previous fix  
**Priority**: ✅ Fixed

---

## 📊 Project Status Dashboard

### Phase 1: Critical Fixes
| Task | Status | Owner | ETA |
|------|--------|-------|-----|
| Analysis | ✅ Complete | Claude | Done |
| Documentation | ✅ Complete | Claude | Done |
| Implementation | ⏳ Not Started | TBD | TBD |
| Code Review | ⏳ Not Started | TBD | TBD |
| Testing | ⏳ Not Started | TBD | TBD |
| Deployment | ⏳ Not Started | TBD | TBD |

### Phase 2: Architectural Improvements
| Task | Status | Owner | ETA |
|------|--------|-------|-----|
| Sticky URL Cards | 📋 Planned | TBD | Future |
| Unified State Model | 📋 Planned | TBD | Future |
| Enhanced UX | 📋 Planned | TBD | Future |

---

## 💬 Communication Channels

### For Questions
- **Implementation questions**: See `POST_COMPOSER_PHASE1_FIXES.md`
- **Architecture questions**: See `POST_COMPOSER_URL_BEHAVIOR_ANALYSIS.md`
- **Testing questions**: See test cases in Phase 1 doc
- **General questions**: Check documentation index

### For Updates
- **Task claims**: Update `POST_COMPOSER_SHARED_TODO.md`
- **Progress updates**: Update status in shared TODO
- **Bugs found**: Add to shared TODO bug section
- **Questions raised**: Add to shared TODO questions section

### For Collaboration
- **Coordinate work**: Check shared TODO before starting
- **Avoid conflicts**: Claim tasks before working on them
- **Share findings**: Document in shared TODO
- **Help others**: Answer questions in shared TODO

---

## 🎓 Learning Resources

### Understanding Facets
Facets are AT Protocol's way of marking up rich text:
```swift
// Example: Link facet
AppBskyRichtextFacet(
    index: ByteSlice(byteStart: 0, byteEnd: 20),
    features: [.appBskyRichtextFacetLink(
        Link(uri: URI("https://example.com"))
    )]
)
```

Byte ranges are in UTF-8, not Swift String indices!

### Understanding UITextView Typing Attributes
```swift
// When user types, new text inherits these attributes
textView.typingAttributes = [
    .font: UIFont.systemFont(ofSize: 17),
    .foregroundColor: UIColor.label,
    .link: URL(string: "https://example.com")  // ⚠️ This causes blue text!
]
```

### Understanding State Synchronization
```
User types → updatePostContent() → PostParser → Facets → updateAttributedText()
                                                              ↓
                                                        RichTextView displays
```

Any break in this chain causes state divergence!

---

## ⚡ Quick Commands

### Build & Test
```bash
# Quick incremental build (iOS)
./quick-build.sh Catbird

# Full clean build
# Use MCP: build_sim with simulatorName: "iPhone 16 Pro"

# Run tests (iOS)
# Use MCP: test_sim with simulatorName: "iPhone 16 Pro"

# Run tests (macOS)
# Use MCP: test_macos with scheme: "Catbird"

# Syntax check individual file
swift -frontend -parse path/to/file.swift
```

### Code Navigation
```bash
# Find all URL-related code
rg "detectedURLs|urlCards|selectedEmbedURL" Catbird/Features/Feed/Views/Components/PostComposer/

# Find manual link facet usage
rg "manualLinkFacets" Catbird/Features/Feed/Views/Components/PostComposer/

# Find UITextView setup
fd "RichTextEditor.swift"
```

### Documentation
```bash
# View documentation in terminal
cat POST_COMPOSER_URL_BEHAVIOR_ANALYSIS.md | less

# Search across all docs
rg "typingAttributes" *.md

# List all related docs
ls -lh POST_COMPOSER*.md
```

---

## 🎯 Next Actions (Pick One!)

### Option A: Implement the Fix
1. Read analysis + Phase 1 docs (25 min)
2. Go to `POST_COMPOSER_SHARED_TODO.md`
3. Claim task `IMPL-001`
4. Start coding!

### Option B: Review the Approach
1. Read all documentation (1 hour)
2. Go to `POST_COMPOSER_SHARED_TODO.md`
3. Claim review section
4. Start analyzing!

### Option C: Test the System
1. Read Phase 1 test cases (20 min)
2. Go to `POST_COMPOSER_SHARED_TODO.md`
3. Claim test section
4. Start testing!

### Option D: Deep Dive Analysis (AI Agents)
1. Read all docs thoroughly (1 hour)
2. Go to `POST_COMPOSER_SHARED_TODO.md`
3. Claim analysis area
4. Start researching!

---

## 📝 Important Notes

### This is Production Code
- No placeholders or TODOs allowed
- All code must be production-ready
- Comprehensive error handling required
- Full test coverage expected

### Swift 6 Strict Concurrency
- All changes must pass Swift 6 concurrency checks
- Use `@MainActor` appropriately
- No data races allowed
- Proper async/await usage

### Cross-Platform Support
- Changes must work on iOS 18+ AND macOS 13+
- Test both platforms thoroughly
- Use platform detection where needed
- No platform-specific hacks

### Backward Compatibility
- Don't break existing drafts
- State migration if needed
- Graceful degradation for old data
- Version transitions handled

---

## 🆘 Getting Unstuck

### If You're Confused About the Problem
→ Read `POST_COMPOSER_URL_BEHAVIOR_ANALYSIS.md` Section 2: "Current Behavior Analysis"

### If You're Unsure How to Implement
→ Read `POST_COMPOSER_PHASE1_FIXES.md` - has code snippets and step-by-step guide

### If You Don't Know What to Work On
→ Check `POST_COMPOSER_SHARED_TODO.md` for unclaimed tasks

### If You Found a New Issue
→ Add it to the "Issues Found" section in shared TODO

### If You Have Questions
→ Add them to the "Open Questions" section in shared TODO

### If Tests Are Failing
→ Check if baseline fails too - might not be your fault!

---

## ✨ Success Looks Like...

### For Users
- Typing feels natural and predictable
- URL cards behave as expected
- No confusing blue text
- Fast, responsive interface

### For Developers
- Clear, maintainable code
- No mysterious state bugs
- Easy to understand flow
- Good test coverage

### For the Project
- Fewer bug reports
- Higher user satisfaction
- Solid foundation for future features
- Technical debt reduced

---

## 🚀 Let's Go!

**Ready to start?** 

1. ✅ You've read this document
2. 📋 Go to `POST_COMPOSER_SHARED_TODO.md`
3. 🎯 Pick a task and claim it
4. 💪 Make it happen!

**Questions?** Add them to the shared TODO and keep moving forward.

**Stuck?** Check the "Getting Unstuck" section above.

**Done?** Mark your task complete in shared TODO and pick another!

---

*Last updated: December 2024*  
*Document owner: Development Team*  
*Status: Active development*

