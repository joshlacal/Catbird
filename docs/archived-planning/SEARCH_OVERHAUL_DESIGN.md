# Search Overhaul Design Document (SRCH-001)

**Status**: Draft  
**Author**: AI Agent  
**Created**: 2025-10-13  
**Target Completion**: Q2 2025  

---

## Executive Summary

This document outlines a comprehensive overhaul of Catbird's search experience across 3 phases:

- **Phase 0** (Research & Audit): 2 weeks - Competitive analysis, performance profiling, user feedback collection
- **Phase 1** (Quick Wins): 6-8 weeks - Performance optimization, discovery improvements, filter simplification
- **Phase 2** (Advanced Features): 8-10 weeks - Advanced search operators, saved searches, real-time updates

**Total Estimated Timeline**: 16-20 weeks  
**Total Tickets**: 22 (1 research + 8 quick wins + 13 advanced features)

---

## Current State Analysis

### Existing Architecture

The search system is well-architected with:

- **State Management**: `RefinedSearchViewModel` (@Observable) with proper state machine
- **States**: idle (discovery) → searching (typeahead) → results → loading
- **Content Types**: All (profiles, posts, feeds, starter packs)
- **Features**: Typeahead, filters, discovery, recent searches, trending topics
- **APIs**: Full AT Protocol search support (actors, posts, feeds, starter packs)

### API Capabilities (Already Available)

The AT Protocol search API supports:
- ✅ `author` filtering
- ✅ `mentions` filtering  
- ✅ `lang` language filtering
- ✅ `domain` filtering
- ✅ `url` filtering
- ✅ `tag` filtering
- ✅ `sort` (top/latest)
- ✅ `since`/`until` date ranges
- ✅ Pagination with cursors

### Identified Pain Points

1. **Discovery**: Empty state could be more engaging with personalized suggestions
2. **Performance**: Debounce timing and state update optimization opportunities
3. **Filters**: Advanced filters are feature-complete but could be more accessible
4. **History**: Recent searches lack swipe-to-delete, bulk clear
5. **Cross-tab**: No way to search from other tabs (e.g., search a user's posts from their profile)
6. **Offline**: No offline search capability or cached results
7. **Saved Searches**: No way to save searches or get notifications
8. **Advanced Operators**: API supports them, but UI doesn't expose all capabilities

---

## Phase 0: Research & Audit (2 weeks)

**Goal**: Comprehensive analysis to inform Phase 1 & 2 priorities

### SRCH-002: Competitive Analysis
**Size**: M (3-5 days)  
**Owner**: UX Lead + Product

**Tasks**:
1. Audit Twitter/X search UX (advanced operators, saved searches, filters)
2. Audit Mastodon search (hashtag discovery, instance-scoped search)
3. Audit Threads search (Instagram integration, trending)
4. Audit Ivory/Ice Cubes (third-party Bluesky clients)
5. Document best practices and differentiators

**Deliverable**: Competitive analysis doc with screenshots and feature matrix

---

### SRCH-003: Performance Profiling
**Size**: M (3-5 days)  
**Owner**: iOS Engineer

**Tasks**:
1. Profile search flow with Instruments (Time Profiler, Allocations)
2. Measure time-to-first-result for each content type
3. Identify state update bottlenecks
4. Measure network latency for search APIs
5. Test on older devices (iPhone 12, iPad Air 3)

**Deliverable**: Performance report with Instruments traces and recommendations

**Tools**:
```bash
# Use xcodebuild-mcp for profiling builds
xcodebuild_mcp:build_sim(
    projectPath="/path/to/Catbird.xcodeproj",
    scheme="Catbird",
    configuration="Release",
    simulatorName="iPhone 12"
)
```

---

### SRCH-004: User Feedback Collection
**Size**: S (1-2 days)  
**Owner**: Product + Community Manager

**Tasks**:
1. Review GitHub issues tagged with "search"
2. Collect feedback from Discord/community channels
3. Survey power users about search pain points
4. Analyze support tickets related to search
5. Create prioritized feedback summary

**Deliverable**: User feedback report with categorized pain points

---

### SRCH-005: Analytics Review
**Size**: S (1-2 days)  
**Owner**: Data Analyst

**Tasks**:
1. Measure search usage metrics (searches/day, success rate)
2. Analyze content type distribution (posts vs profiles vs feeds)
3. Identify drop-off points in search funnel
4. Measure filter usage (which filters are most used)
5. Track trending topic engagement

**Deliverable**: Analytics dashboard and insights report

---

## Phase 1: Quick Wins (6-8 weeks)

**Goal**: High-impact improvements with existing architecture

### SRCH-006: Performance Optimization
**Size**: L (5-8 days)  
**Priority**: P0  
**Dependencies**: SRCH-003

**User Story**: As a user, I want search to feel instant and responsive

**Technical Approach**:
1. Reduce debounce from 300ms to 150ms (test for server load)
2. Optimize state updates to batch related changes
3. Implement result prefetching for trending topics
4. Cache typeahead results for 60 seconds
5. Use `UIUpdateLink` for smooth scroll performance (iOS 18+)

**Files**:
- `Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift` (debounce timing)
- `Catbird/Features/Search/Services/SearchCacheManager.swift` (new file for caching)

**Acceptance Criteria**:
- [ ] Time-to-first-result < 200ms (was ~500ms)
- [ ] Scroll at 60fps on iPhone 12
- [ ] No state update hitches during typing
- [ ] Instruments confirms < 20MB search memory footprint

**Success Metrics**:
- 40% reduction in perceived search latency
- 30% increase in search completion rate

---

### SRCH-007: Discovery Improvements
**Size**: M (3-5 days)  
**Priority**: P1

**User Story**: As a new user, I want to discover interesting content without knowing what to search for

**Technical Approach**:
1. Add "Suggested for you" section with personalized accounts (based on follows graph)
2. Enhance trending topics with topic summaries (use `TopicSummaryService`)
3. Add "Popular feeds" discovery section
4. Implement starter pack recommendations
5. Add iOS 26 Liquid Glass to discovery cards

**Files**:
- `Catbird/Features/Search/Views/DiscoveryView.swift` (new file)
- `Catbird/Features/Search/Services/DiscoveryService.swift` (new file)
- `Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift` (add discovery state)

**Acceptance Criteria**:
- [ ] "Suggested for you" shows 5-10 personalized accounts
- [ ] Trending topics display summary with engagement stats
- [ ] "Popular feeds" section shows top 5 feeds by subscribers
- [ ] Starter packs section shows 3 curated packs
- [ ] All discovery cards use iOS 26 Liquid Glass effects

**Success Metrics**:
- 25% of users engage with discovery content (tap on suggestion)
- 15% increase in follows from search tab

---

### SRCH-008: Search History Polish
**Size**: S (2-3 days)  
**Priority**: P1

**User Story**: As a user, I want to manage my search history easily

**Technical Approach**:
1. Add swipe-to-delete for individual recent searches
2. Add "Clear All" button with confirmation alert
3. Limit recent searches to 20 items (auto-prune oldest)
4. Add timestamps to recent searches ("2h ago", "Yesterday")
5. Persist recent profile searches separately

**Files**:
- `Catbird/Features/Search/Services/SearchHistoryManager.swift` (enhance existing)
- `Catbird/Features/Search/Views/Components/RecentSearchRow.swift` (new file)

**Acceptance Criteria**:
- [ ] Swipe left on search → Delete button appears
- [ ] "Clear All" prompts confirmation before deletion
- [ ] Only 20 most recent searches stored
- [ ] Timestamps display relative time (< 24h) or date
- [ ] Profile searches show avatar thumbnail

**Success Metrics**:
- 10% of users use "Clear All" feature
- Reduced clutter in recent searches

---

### SRCH-009: Filter Simplification
**Size**: M (3-5 days)  
**Priority**: P1

**User Story**: As a user, I want to filter search results without being overwhelmed

**Technical Approach**:
1. Move advanced filters to separate sheet (keep visible: Content Type, Sort, Date)
2. Add "Filters" badge count when advanced filters active
3. Simplify date picker (show presets: Today, This Week, This Month, This Year)
4. Add filter presets: "My Network" (from follows), "Media Only", "Recent"
5. Persist filter preferences per content type

**Files**:
- `Catbird/Features/Search/Views/FilterViews/SimplifiedFilterView.swift` (new file)
- `Catbird/Features/Search/Views/FilterViews/AdvancedFilterView.swift` (existing, enhance)
- `Catbird/Features/Search/Models/FilterPreset.swift` (new file)

**Acceptance Criteria**:
- [ ] Only 3 filters visible by default (Content, Sort, Date)
- [ ] "Advanced" button shows badge count when filters active
- [ ] Date presets work correctly with API (since/until params)
- [ ] Filter presets apply multiple filters at once
- [ ] Preferences persist across app restarts

**Success Metrics**:
- 40% increase in filter usage
- 20% reduction in filter sheet dismissals (less confusion)

---

### SRCH-010: Result Ranking Improvements
**Size**: M (3-5 days)  
**Priority**: P1  
**Dependencies**: SRCH-005

**User Story**: As a user, I want the most relevant results at the top

**Technical Approach**:
1. Boost results from followed users (API doesn't provide this, client-side sort)
2. De-rank spam/low-quality content (use moderation labels)
3. Apply user's muted words to search results
4. Boost verified accounts for profile searches
5. Use engagement signals (likes, reposts) for tiebreaking

**Files**:
- `Catbird/Features/Search/Services/SearchRankingService.swift` (new file)
- `Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift` (integrate ranking)

**Acceptance Criteria**:
- [ ] Followed users appear in top 5 results (if relevant)
- [ ] Muted words filter applied to all results
- [ ] Spam content with moderation labels de-ranked
- [ ] Verified accounts boosted in profile searches
- [ ] Ranking respects user's moderation preferences

**Success Metrics**:
- 15% increase in result click-through rate
- 10% decrease in "no results found" searches (better ranking)

---

### SRCH-011: Error State Polish
**Size**: S (2-3 days)  
**Priority**: P1

**User Story**: As a user, I want helpful feedback when searches fail

**Technical Approach**:
1. Distinguish network errors vs empty results vs API errors
2. Add retry button for network failures
3. Add search suggestions for empty results ("Try broader terms", "Check spelling")
4. Show offline indicator with cached results
5. Add Liquid Glass to error states

**Files**:
- `Catbird/Features/Search/Views/Components/SearchErrorView.swift` (new file)
- `Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift` (enhance error handling)

**Acceptance Criteria**:
- [ ] Network errors show retry button
- [ ] Empty results show helpful suggestions
- [ ] Offline mode shows cached results with indicator
- [ ] API errors display user-friendly message
- [ ] All error states use Liquid Glass design

**Success Metrics**:
- 30% reduction in search abandonment after errors
- 20% increase in retry attempts

---

### SRCH-012: iOS 26 Liquid Glass Integration
**Size**: M (3-5 days)  
**Priority**: P1

**User Story**: As an iOS 26 user, I want search to use the new Liquid Glass design

**Technical Approach**:
1. Apply `.glassEffect()` to search bar container
2. Use `GlassEffectContainer` for result cards
3. Add glass morphing transitions for filter sheet
4. Use interactive glass for trending topic cards
5. Ensure backward compatibility (iOS 18+ fallback to Material)

**Files**:
- `Catbird/Features/Search/Views/RefinedSearchView.swift` (add glass effects)
- `Catbird/Features/Search/Views/Components/*.swift` (update all result rows)

**Acceptance Criteria**:
- [ ] Search bar uses `.glassEffect()` with `.capsule` shape
- [ ] Result cards grouped in `GlassEffectContainer`
- [ ] Filter sheet morphs smoothly with `.transition(.glassEffect)`
- [ ] Trending cards use `.interactive()` glass
- [ ] Falls back to `Material.regularMaterial` on iOS 18-25

**Success Metrics**:
- Visual design parity with iOS 26 system apps
- No performance regressions

---

### SRCH-013: Cross-Platform Polish
**Size**: M (3-5 days)  
**Priority**: P2

**User Story**: As a macOS user, I want search to feel native to Mac

**Technical Approach**:
1. Add keyboard shortcuts (⌘F for search, ⌘⇧F for advanced)
2. Use macOS-native search field styling
3. Optimize result layout for wider screens
4. Add macOS-specific hover states
5. Support Spotlight-style quick search

**Files**:
- `Catbird/Features/Search/Views/RefinedSearchView.swift` (platform-specific modifiers)
- `Catbird/Core/Extensions/CrossPlatformUI.swift` (search field helpers)

**Acceptance Criteria**:
- [ ] ⌘F focuses search field on macOS
- [ ] Search field uses macOS native styling
- [ ] Results use 2-column layout on Mac (width > 768)
- [ ] Hover states show interactive feedback
- [ ] Quick search window accessible via global shortcut

**Success Metrics**:
- 15% increase in macOS search engagement
- Keyboard shortcut usage by 30% of Mac users

---

## Phase 2: Advanced Features (8-10 weeks)

**Goal**: Differentiate Catbird with power-user features

### SRCH-014: Advanced Search Operators
**Size**: L (5-8 days)  
**Priority**: P1  
**Dependencies**: SRCH-009

**User Story**: As a power user, I want to use advanced search operators like Twitter/X

**Technical Approach**:
1. Parse query for operators: `from:@user`, `to:@user`, `lang:en`, `has:media`
2. Map operators to AT Protocol API params (author, mentions, lang, domain, url, tag)
3. Add operator autocomplete in search field
4. Show active operators as chips below search bar
5. Support operator chaining: `from:@alice lang:en has:media`

**Operators to Support**:
- `from:@handle` - Posts by specific user (maps to `author`)
- `to:@handle` - Posts mentioning user (maps to `mentions`)
- `lang:code` - Posts in language (maps to `lang`)
- `has:media` / `has:video` / `has:links` - Content type filters
- `domain:example.com` - Posts with links to domain (maps to `domain`)
- `url:example.com/page` - Posts with specific URL (maps to `url`)
- `tag:hashtag` - Posts with tag (maps to `tag`)
- `since:2024-01-01` - Posts after date (maps to `since`)
- `until:2024-12-31` - Posts before date (maps to `until`)

**Files**:
- `Catbird/Features/Search/Services/SearchQueryParser.swift` (new file)
- `Catbird/Features/Search/Views/Components/OperatorChipView.swift` (new file)
- `Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift` (integrate parser)

**Acceptance Criteria**:
- [ ] All 9 operators parse correctly and map to API params
- [ ] Autocomplete suggests operators as user types
- [ ] Active operators display as removable chips
- [ ] Invalid operators show error hint
- [ ] Operators work in combination
- [ ] Help sheet explains all operators

**Success Metrics**:
- 20% of searches use at least one operator
- 5% of searches use 2+ operators (power users)

---

### SRCH-015: Saved Searches with Notifications
**Size**: XL (8-12 days)  
**Priority**: P1

**User Story**: As a user, I want to save searches and get notified of new results

**Technical Approach**:
1. Add "Save Search" button to search results toolbar
2. Store saved searches with query, filters, and notification preferences
3. Background task checks saved searches every 15 minutes
4. Send local notification when new results found
5. Sync saved searches across devices (iCloud or server)

**Files**:
- `Catbird/Features/Search/Models/SavedSearch.swift` (enhance existing)
- `Catbird/Features/Search/Services/SavedSearchManager.swift` (new file)
- `Catbird/Features/Search/BackgroundTasks/SearchRefreshTask.swift` (new file)
- `Catbird/Features/Search/Views/SavedSearchesView.swift` (new file)

**Acceptance Criteria**:
- [ ] "Save" button appears in results toolbar
- [ ] User can configure notification frequency (off, hourly, daily)
- [ ] Background task runs every 15 minutes (when app backgrounded)
- [ ] Notifications show result count and preview
- [ ] Saved searches sync via iCloud (CloudKit)
- [ ] Max 10 saved searches per user

**Success Metrics**:
- 10% of users save at least one search
- 5% enable notifications for saved searches

---

### SRCH-016: Search Across Tabs
**Size**: M (3-5 days)  
**Priority**: P1

**User Story**: As a user, I want to search from any tab without switching to Search

**Technical Approach**:
1. Add global search shortcut (⌘K on Mac, swipe down on iOS)
2. Present modal search sheet from any tab
3. Preserve current tab state when searching
4. Add "Search this user's posts" from profile view
5. Add "Search in this feed" from feed view

**Files**:
- `Catbird/Core/Navigation/GlobalSearchSheet.swift` (new file)
- `Catbird/Core/Navigation/AppNavigationManager.swift` (add search navigation)
- `Catbird/Features/Profile/Views/ProfileView.swift` (add search button)

**Acceptance Criteria**:
- [ ] ⌘K opens search sheet on macOS
- [ ] Swipe down on iOS opens search sheet
- [ ] Search sheet dismisses back to originating tab
- [ ] "Search posts" button in profile toolbar
- [ ] "Search in feed" button in feed menu
- [ ] Search results respect context (user/feed scope)

**Success Metrics**:
- 15% of searches originate from non-Search tabs
- 25% increase in profile→post searches

---

### SRCH-017: Real-Time Search Updates
**Size**: L (5-8 days)  
**Priority**: P2

**User Story**: As a user, I want to see new results as they're posted without refreshing

**Technical Approach**:
1. Use Bluesky's Firehose API for real-time updates
2. Filter firehose for matching search query
3. Show "New results" banner at top of results
4. Auto-refresh when banner tapped
5. Respect user's auto-update preference

**Files**:
- `Catbird/Features/Search/Services/SearchRealtimeService.swift` (new file)
- `Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift` (integrate real-time)
- `Catbird/Core/Services/FirehoseManager.swift` (enhance existing)

**Acceptance Criteria**:
- [ ] Firehose connection established for active searches
- [ ] "New results" banner appears when matches found
- [ ] Tapping banner inserts new results at top
- [ ] Auto-update can be disabled in settings
- [ ] Connection closes when search inactive (battery)

**Success Metrics**:
- 30% of active searches receive real-time updates
- 80% of users tap banner to load new results

---

### SRCH-018: Search Result Sharing
**Size**: S (2-3 days)  
**Priority**: P2

**User Story**: As a user, I want to share search results with others

**Technical Approach**:
1. Add share button to search results toolbar
2. Generate shareable link with query and filters
3. Deep link handler processes shared search links
4. Support sharing individual results vs entire query
5. Add "Copy Search Query" for operator-based searches

**Files**:
- `Catbird/Features/Search/Views/RefinedSearchView.swift` (add share button)
- `Catbird/Core/Networking/DeepLinkHandler.swift` (add search URL scheme)
- `Catbird/Features/Search/Services/SearchSharingService.swift` (new file)

**Acceptance Criteria**:
- [ ] Share button in results toolbar
- [ ] Shared link format: `catbird://search?q=query&filters=...`
- [ ] Deep link opens app to search results
- [ ] "Copy Query" copies operator syntax
- [ ] Share sheet includes query preview

**Success Metrics**:
- 5% of searches result in shares
- 20% of shared links clicked by recipients

---

### SRCH-019: Voice Search Integration
**Size**: M (3-5 days)  
**Priority**: P2  
**Platform**: iOS only

**User Story**: As a mobile user, I want to search using voice input

**Technical Approach**:
1. Add microphone button to search field
2. Use `SFSpeechRecognizer` for voice-to-text
3. Support live transcription while speaking
4. Auto-submit search when user pauses (2s silence)
5. Show voice waveform visualization

**Files**:
- `Catbird/Features/Search/Services/VoiceSearchService.swift` (new file)
- `Catbird/Features/Search/Views/Components/VoiceSearchButton.swift` (new file)
- `Catbird/Features/Search/Views/Components/VoiceWaveformView.swift` (new file)

**Acceptance Criteria**:
- [ ] Microphone button in search field (iOS only)
- [ ] Speech recognition accuracy > 90%
- [ ] Live transcription updates search field
- [ ] Auto-submit after 2s pause
- [ ] Waveform visualizes audio input
- [ ] Requests microphone permission

**Success Metrics**:
- 3% of iOS searches use voice input
- 85% voice search success rate

---

### SRCH-020: Search Analytics Dashboard
**Size**: M (3-5 days)  
**Priority**: P2

**User Story**: As a user, I want to see my search history and insights

**Technical Approach**:
1. Track search metrics (queries, clicks, content type preferences)
2. Build analytics dashboard showing:
   - Most searched terms (word cloud)
   - Search activity heatmap (day/hour)
   - Top content types searched
   - Average results per search
3. Privacy controls to clear analytics
4. Export search history as JSON

**Files**:
- `Catbird/Features/Search/Services/SearchAnalyticsService.swift` (new file)
- `Catbird/Features/Search/Views/SearchAnalyticsView.swift` (new file)
- `Catbird/Features/Search/Models/SearchMetrics.swift` (new file)

**Acceptance Criteria**:
- [ ] Dashboard accessible from search settings
- [ ] Word cloud shows top 20 search terms
- [ ] Heatmap displays activity by day/hour
- [ ] Content type breakdown (pie chart)
- [ ] "Clear Analytics" button in privacy settings
- [ ] Export as JSON file

**Success Metrics**:
- 8% of users view analytics dashboard
- Average 2 minutes spent exploring insights

---

### SRCH-021: Offline Search
**Size**: XL (8-12 days)  
**Priority**: P2

**User Story**: As a user, I want to search my cached content when offline

**Technical Approach**:
1. Index cached posts, profiles, feeds locally (CoreData + Core Spotlight)
2. Implement full-text search on indexed content
3. Show "Offline Results" badge when network unavailable
4. Sync index incrementally as content loads
5. Limit index to 10,000 most recent items (storage)

**Files**:
- `Catbird/Core/Storage/SearchIndex.swift` (new file)
- `Catbird/Features/Search/Services/OfflineSearchService.swift` (new file)
- `Catbird/Features/Search/ViewModels/RefinedSearchViewModel.swift` (offline mode)

**Acceptance Criteria**:
- [ ] Indexed content searchable offline
- [ ] "Offline Results" badge visible when offline
- [ ] Index limited to 10,000 items
- [ ] Incremental sync every 15 minutes
- [ ] Search results marked as "Cached" with timestamp
- [ ] Index size < 50MB

**Success Metrics**:
- 100% of offline searches return cached results (if indexed)
- Index build time < 5 seconds

---

### SRCH-022: Personalized Search Ranking
**Size**: XL (8-12 days)  
**Priority**: P2  
**Dependencies**: SRCH-020

**User Story**: As a user, I want search results personalized to my interests

**Technical Approach**:
1. Build user interest profile (topics, accounts, content types)
2. Apply ML ranking model (on-device Core ML)
3. Boost results matching user interests
4. De-rank content user previously dismissed
5. A/B test ranking with ABTestingFramework

**Files**:
- `Catbird/Features/Search/Services/PersonalizationService.swift` (new file)
- `Catbird/Features/Search/ML/SearchRankingModel.mlmodel` (Core ML model)
- `Catbird/Features/Search/Services/SearchRankingService.swift` (integrate ML)

**Acceptance Criteria**:
- [ ] Interest profile built from user activity
- [ ] Core ML model ranks results (< 100ms latency)
- [ ] Boosted results appear in top 10
- [ ] Dismissed content de-ranked
- [ ] A/B test compares ML vs default ranking
- [ ] Privacy: all ML on-device

**Success Metrics**:
- 25% increase in result click-through (A/B test)
- 15% increase in search satisfaction (survey)

---

### SRCH-023: Trending Topics Expansion
**Size**: M (3-5 days)  
**Priority**: P2

**User Story**: As a user, I want to explore trending topics in depth

**Technical Approach**:
1. Add "Trending" tab to search (alongside All/Profiles/Posts/Feeds)
2. Show trending topic details (volume, velocity, related topics)
3. Group trending results by topic
4. Add topic following (notifications for new trending topics)
5. Show topic sentiment (positive/neutral/negative)

**Files**:
- `Catbird/Features/Search/Views/TrendingTopicsView.swift` (enhance existing)
- `Catbird/Features/Search/Services/TopicSummaryService.swift` (enhance existing)
- `Catbird/Features/Search/Models/TrendingTopic.swift` (new file)

**Acceptance Criteria**:
- [ ] "Trending" tab shows topic list
- [ ] Topic detail view shows volume and velocity
- [ ] Related topics suggested
- [ ] "Follow Topic" enables notifications
- [ ] Sentiment indicator (emoji or color)

**Success Metrics**:
- 20% of users explore Trending tab
- 5% follow at least one topic

---

### SRCH-024: Search Suggestions & Autocorrect
**Size**: M (3-5 days)  
**Priority**: P2

**User Story**: As a user, I want helpful suggestions when I make typos

**Technical Approach**:
1. Implement fuzzy matching for misspelled queries
2. Show "Did you mean...?" suggestions
3. Autocorrect common typos automatically
4. Learn from user corrections (local model)
5. Suggest popular searches based on partial input

**Files**:
- `Catbird/Features/Search/Services/SearchSuggestionService.swift` (new file)
- `Catbird/Features/Search/Services/FuzzyMatcher.swift` (new file)
- `Catbird/Features/Search/Views/Components/SearchSuggestionView.swift` (new file)

**Acceptance Criteria**:
- [ ] Fuzzy matching suggests corrections (edit distance ≤ 2)
- [ ] "Did you mean?" appears below search field
- [ ] Common typos autocorrect (e.g., "hte" → "the")
- [ ] User corrections improve suggestions
- [ ] Popular searches suggested as user types

**Success Metrics**:
- 30% of typos result in successful correction
- 15% increase in search success rate

---

### SRCH-025: Advanced Filter Presets
**Size**: M (3-5 days)  
**Priority**: P2  
**Dependencies**: SRCH-009

**User Story**: As a user, I want to save custom filter combinations

**Technical Approach**:
1. Allow saving filter combinations as presets
2. Quick access to presets from filter menu
3. Share presets with other users (export as link)
4. Community presets gallery (curated by team)
5. Preset templates for common use cases

**Files**:
- `Catbird/Features/Search/Models/FilterPreset.swift` (enhance existing)
- `Catbird/Features/Search/Views/FilterPresetGalleryView.swift` (new file)
- `Catbird/Features/Search/Services/FilterPresetService.swift` (new file)

**Acceptance Criteria**:
- [ ] "Save as Preset" button in filter sheet
- [ ] Presets accessible from filter menu
- [ ] Share preset as link (deep link to filters)
- [ ] Gallery shows 10 curated presets
- [ ] Templates: "My Network", "Media", "Today", "This Week"

**Success Metrics**:
- 8% of users save at least one preset
- 12% use community presets

---

## Technical Architecture

### State Management

**Current**: `@Observable RefinedSearchViewModel` - **Keep**  
**Why**: Modern Swift 6 pattern, good performance, proper actor isolation

**Enhancements**:
- Add `SearchCacheManager` actor for thread-safe caching
- Add `SearchAnalyticsService` for metrics tracking
- Add `SearchQueryParser` for operator parsing

### API Optimization

**Current**: Direct AT Protocol calls - **Keep**  
**Enhancements**:
- Batch requests for multi-content-type searches
- Request deduplication (same query in flight)
- Response caching with TTL (60s for typeahead, 5min for results)

### Caching Strategy

**Tiers**:
1. **In-Memory**: Typeahead results (60s TTL, 100 items max)
2. **Persistent**: Saved searches (iCloud sync)
3. **Offline Index**: CoreData + Core Spotlight (10k items, 7 day TTL)

### Analytics Instrumentation

**Track**:
- Search initiated (query length, content type)
- Search completed (result count, time-to-first-result)
- Result clicked (position, content type)
- Filter applied (filter type, preset)
- Operator used (operator type, combination)
- Voice search (accuracy, success rate)
- Share search (format, recipient)

**Privacy**: All analytics stored locally, opt-in for telemetry

### A/B Testing Integration

Use `ABTestingFramework` for:
- Ranking algorithm variants (SRCH-010, SRCH-022)
- Debounce timing (SRCH-006)
- Filter UI variations (SRCH-009)
- Discovery content layouts (SRCH-007)

---

## Success Metrics

### Phase 0 (Research)
- ✅ Competitive analysis doc completed
- ✅ Performance baseline established
- ✅ User feedback categorized and prioritized

### Phase 1 (Quick Wins)
- 40% reduction in perceived search latency
- 30% increase in search completion rate
- 25% of users engage with discovery content
- 40% increase in filter usage
- 15% increase in result click-through rate

### Phase 2 (Advanced Features)
- 20% of searches use advanced operators
- 10% of users save at least one search
- 15% of searches originate from non-Search tabs
- 30% of active searches receive real-time updates
- 25% increase in personalized result click-through

### Overall Goals
- Search engagement increases by 50% (sessions/user)
- Search satisfaction score > 4.2/5.0 (user survey)
- Time-to-first-result < 200ms (p95)
- Zero crashes in search flow (production)

---

## Risks & Mitigation

### Performance Risks
- **Risk**: Real-time updates consume battery
- **Mitigation**: Auto-disable after 5 minutes, opt-in setting

### Privacy Risks
- **Risk**: Personalization requires tracking user behavior
- **Mitigation**: All ML on-device, opt-in analytics, clear privacy policy

### API Risks
- **Risk**: AT Protocol search API limitations
- **Mitigation**: Client-side filtering/ranking as fallback

### Scope Risks
- **Risk**: Phase 2 features may slip timeline
- **Mitigation**: Prioritize P1 tickets, defer P2 to later release

---

## Dependencies

### Internal
- Navigation system refactor (if needed for SRCH-016)
- ABTestingFramework integration (SRCH-010, SRCH-022)
- Background tasks framework (SRCH-015)

### External
- AT Protocol API stability
- Bluesky Firehose uptime (SRCH-017)
- Core ML model training (SRCH-022)

---

## Rollout Plan

### Phase 0 (Week 1-2)
- Complete research and audit
- Present findings to team
- Finalize Phase 1 priorities

### Phase 1 (Week 3-10)
- Sprint 1 (Week 3-4): SRCH-006, SRCH-008
- Sprint 2 (Week 5-6): SRCH-007, SRCH-011
- Sprint 3 (Week 7-8): SRCH-009, SRCH-010
- Sprint 4 (Week 9-10): SRCH-012, SRCH-013, testing

### Phase 2 (Week 11-20)
- Sprint 5 (Week 11-13): SRCH-014, SRCH-016
- Sprint 6 (Week 14-16): SRCH-015, SRCH-017
- Sprint 7 (Week 17-18): SRCH-018, SRCH-019, SRCH-020
- Sprint 8 (Week 19-20): SRCH-021, SRCH-022, testing

### Beta Testing
- Week 21-22: Internal dogfooding
- Week 23-24: Public TestFlight beta
- Week 25: Production release

---

## Open Questions

1. Should we build custom search indexing or use Core Spotlight exclusively?
2. What's the server load impact of reducing debounce to 150ms?
3. Should saved searches sync via iCloud or server (custom backend)?
4. Do we need Bluesky team approval for Firehose-based real-time search?
5. What's the priority of voice search vs other Phase 2 features?

---

## Appendix: Ticket Summary

### Phase 0 (Research)
- SRCH-002: Competitive Analysis (M)
- SRCH-003: Performance Profiling (M)
- SRCH-004: User Feedback Collection (S)
- SRCH-005: Analytics Review (S)

### Phase 1 (Quick Wins)
- SRCH-006: Performance Optimization (L) - P0
- SRCH-007: Discovery Improvements (M) - P1
- SRCH-008: Search History Polish (S) - P1
- SRCH-009: Filter Simplification (M) - P1
- SRCH-010: Result Ranking Improvements (M) - P1
- SRCH-011: Error State Polish (S) - P1
- SRCH-012: iOS 26 Liquid Glass Integration (M) - P1
- SRCH-013: Cross-Platform Polish (M) - P2

### Phase 2 (Advanced Features)
- SRCH-014: Advanced Search Operators (L) - P1
- SRCH-015: Saved Searches with Notifications (XL) - P1
- SRCH-016: Search Across Tabs (M) - P1
- SRCH-017: Real-Time Search Updates (L) - P2
- SRCH-018: Search Result Sharing (S) - P2
- SRCH-019: Voice Search Integration (M) - P2
- SRCH-020: Search Analytics Dashboard (M) - P2
- SRCH-021: Offline Search (XL) - P2
- SRCH-022: Personalized Search Ranking (XL) - P2
- SRCH-023: Trending Topics Expansion (M) - P2
- SRCH-024: Search Suggestions & Autocorrect (M) - P2
- SRCH-025: Advanced Filter Presets (M) - P2

**Total**: 25 tickets (4 research + 8 quick wins + 13 advanced features)

---

## Next Steps

1. **Review this design doc** with product and engineering leads
2. **Prioritize Phase 0 tasks** and assign owners
3. **Create GitHub issues** for all SRCH-XXX tickets
4. **Set up project board** with Phase 0/1/2 columns
5. **Schedule kickoff meeting** for Phase 0 (Week 1)

---

*Document Version: 1.0*  
*Last Updated: 2025-10-13*
