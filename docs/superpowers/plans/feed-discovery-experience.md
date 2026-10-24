# Feed Discovery Experience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task after product review. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make discovering, previewing and saving a feed directly accessible, with truthful feedback and an optional onboarding entry.

**Architecture:** Evolve the active AddFeedSheet rather than introducing another discovery surface. A session-owned discovery model manages query/pagination, while one membership action layer returns explicit save/pin outcomes. The start page, discovery results and preview share URI-based library state.

**Tech Stack:** SwiftUI, Swift Observation, Petrel, existing PreferencesManager and state invalidation bus; no new dependency or backend contract.

**Spec:** [Feed discovery experience proposal](../../design-docs/feed-discovery-experience-proposal.md)

## Global Constraints

- Status is **approved for isolated implementation** by the originating user. Use the always-visible labeled Add Feed row. Broader unrelated typography/group redesign remains outside scope. No phone install, push, or deploy.
- Preserve the integrated banner, ambient blur, concentric geometry, native search, iOS 27 reorder support, and rounder main card.
- Keep large icons, Liquid Glass, navigation stack and existing toolbar actions.
- Keep `appState.circlesEnabled`; do not infer eligibility or duplicate consent/probe logic.
- Do not modify canonical during the current signed phone build. Coordinate with integration task `01a09aa7-6232-76c2-bc59-568ec2dd00a1` before any future integration/build.
- iOS 18 minimum; preserve iOS 26 behavior and guard newer APIs. Follow existing macOS conditional compilation.
- Do not insert a mandatory onboarding step or reset completed onboarding.
- Generated API files are read-only. Changes to schemas or generated clients are outside this version.
- jj is the only history writer. Seal each independently reviewed unit, immediately run `jj new`, and do not seal another actor's work.

## Review decision

Approved: the existing labeled Add Feed row becomes visible in normal mode below the title/actions row. Implement the full discovery, preview, explicit Save/Pin/Open, feedback, and optional onboarding flow. Coordinate canonical integration and serial builds with the integration owner.

### Task 1: Explicit, reliable library actions

**Files:** Create `Catbird/Features/Feed/Services/FeedLibraryActions.swift`; modify `Catbird/Features/Feed/Views/AddFeedSheet.swift`, `FeedDiscoveryHeaderView.swift`, and `FeedScreen.swift`; inspect `Catbird/Core/State/PreferencesManager.swift` and the Preferences model before choosing its write seam. Add `CatbirdTests/FeedLibraryActionsTests.swift`.

**Interfaces:** Consume the active account's PreferencesManager and invalidation bus. Produce one explicit operation rather than a subscription toggle:

```swift
enum FeedLibraryDestination: Equatable { case saved, pinned }
enum FeedLibraryMembership: Equatable { case absent, saved, pinned }
// FeedLibraryActions is @MainActor and scoped to an AppState/account.
// The async operation returns only after the chosen persistence contract succeeds.
func add(_ uri: ATProtocolURI, to destination: FeedLibraryDestination) async throws -> FeedLibraryMembership
```

- [ ] Inspect saveAndSyncPreferences and its local/server failure contract. Decide what “Saved” can honestly guarantee. Preserve original membership if the operation fails; if existing storage intentionally persists an offline write, represent that as pending sync instead of reporting a server-confirmed save. Keep unrelated preference fields intact.
- [ ] Add tests named `addPreservesDefaultAndOtherFields`, `addingExistingFeedIsIdempotent`, `pinPreservesOtherPinnedOrder`, `saveFailureDoesNotReportSuccess`, and `rapidSameFeedAddsPerformOneWrite`. Use a fake writer that can suspend/fail; assert exact pinned/saved URI arrays and result state after completion.
- [ ] Implement account-scoped per-URI in-flight protection and an explicit add operation. Reuse the established preference mutation mechanism; do not introduce a second source of library membership or overwrite whole preference snapshots after an await.
- [ ] Replace the discovery row's add/remove toggle with Add when absent and a labeled Saved/Pinned state when present. Expose removal through an explicit manage action. Do not change unrelated feed-header Like, Report, Share or Ask actions.
- [ ] Surface per-feed failure and retry on the initiating row/preview. Send feed-list invalidation only after the successful operation and update all visible membership from the resulting library snapshot.
- [ ] Run the focused tests after the current phone build allows test work; inspect both local state and fake server failures. Seal this unit with jj and immediately start a fresh working copy.

### Task 2: Query and browse state that cannot become stale

**Files:** Create `Catbird/Features/Feed/ViewModels/FeedDiscoveryViewModel.swift` and `Catbird/Features/Feed/Services/FeedDiscoveryProvider.swift`; modify `AddFeedSheet.swift`; add `CatbirdTests/FeedDiscoveryViewModelTests.swift`.

**Interfaces:** Provider adapts the existing `getPopularFeedGenerators` endpoint; inspect its installed generated Parameters/Output for `query`, `limit`, and `cursor` before wiring them. Use this boundary for deterministic tests:

```swift
struct FeedDiscoveryPage {
  let feeds: [AppBskyFeedDefs.GeneratorView]
  let cursor: String?
}
protocol FeedDiscoveryProviding {
  func page(query: String?, cursor: String?) async throws -> FeedDiscoveryPage
}
```

The model owns trimmed query, items, cursor, initial loading, refresh loading, paging error and an account/request generation. Membership is supplied from Task 1's account-owned library snapshot rather than fetched by every row.

- [ ] Add controlled-response tests: `olderQueryCannotReplaceNewerQuery`, `clearingQueryRestoresBrowse`, `accountChangeRejectsPriorResponse`, `pagingDeduplicatesURIs`, `pagingFailureRetainsItemsAndCursor`, and `cancelledSearchDoesNotShowError`. Complete responses deliberately out of order and assert visible URI order, cursor and error placement.
- [ ] Replace unstructured searchForFeeds/loadPopularFeeds state changes with model methods for submit, query change, retry and next page. Debounce text changes by 250 ms; submit bypasses the delay. Capture query/account generation before awaiting, and reject mismatches afterward even if cancellation was ignored by transport.
- [ ] Replace the custom TextField with native searchable. Use “Search feeds” in discovery, retaining “Search your feeds” on the library page. Keep browse/results visible during refresh; show the appropriate initial, empty, paging-error or query-error state without clearing useful content unnecessarily.
- [ ] Label unqueried results Popular. Preserve response order and avoid invented topical/trending classifications. Offer explicit paging at the end of the list; hide it when cursor is nil and guard duplicate in-flight page requests.
- [ ] Run the focused state tests and, when host capacity is available, verify keyboard submit, clear, cancel and retry on an iOS simulator. Seal and immediately run jj new.

### Task 3: One discover/preview/add journey and visible entry

**Files:** Modify `FeedsStartPage.swift`, `AddFeedSheet.swift`, `FeedDiscoveryHeaderView.swift`, and `FeedScreen.swift`; add `CatbirdUITests/FeedDiscoveryJourneyTests.swift` using the repository's existing authenticated fixture conventions.

**Interfaces:** Start-page presentation supplies an optional initial query. The discovery session owns the navigation path and Task 2's model. Preview consumes a feed URI and Task 1 membership/actions; it must not create a second discovery model or a nested preview sheet.

```swift
// Proposed AddFeedSheet input; final naming should follow local conventions.
init(initialQuery: String = "")
// Rows push the existing URI-based destination into the sheet's NavigationStack.
// Library-empty and no-local-match actions present the same sheet.
```

- [ ] Apply the entry option chosen in review. For the recommended option, move the existing addFeedButton call outside the edit-only branch, label it Add Feed, and keep its current rounded treatment. Keep the edit-only Done control and delete badges unchanged.
- [ ] Add an explicit Discover more feeds action to a nonempty local query with zero matches, opening AddFeedSheet with that query. Do not change the local search source automatically.
- [ ] Replace the nested preview sheet with a push in the existing discovery navigation stack. Preserve the model, query and scroll position on Back. Close dismisses discovery; Open feed deliberately selects the feed and exits.
- [ ] Use Add/Saving/Saved/Pinned/error states from Task 1 in both the result and preview. After success, show Added to Saved and an optional Pin to start page action. Keep the sheet open for more selections. Do not wire the currently dormant pinConfirmationSheet as a mandatory extra step.
- [ ] Verify normal-mode entry, preview/back preservation, add destination, repeat-add behavior, pin order, deliberate open and visible failure retry. Use a deterministic fixture for UI assertions, then verify one real account's save and persistence after reopening. Test large text, compact width, RTL and Reduce Transparency.
- [ ] Seal and immediately run jj new after evidence is recorded. Keep any chosen heading/typography/group-surface redesign out of this unit unless separately approved.

### Task 4: Optional onboarding, without migration surprises

**Files:** Modify `Catbird/Core/Onboarding/WelcomeOnboardingView.swift`, `OnboardingModels.swift`, and `Catbird/Core/State/OnboardingManager.swift` only if account-scoped acknowledgement is needed; add `CatbirdTests/FeedDiscoveryOnboardingTests.swift`.

**Interfaces:** Finish presents the same AddFeedSheet. Existing currentStep values 0–3 and hasCompletedWelcome retain their meanings. A new first-add explanation acknowledgement, if added, is keyed by account DID and does not bump/reset the global onboarding version.

- [ ] Add tests `existingStepIndicesKeepMeaning`, `completedAccountDoesNotReplayWelcome`, `skippingDiscoveryDoesNotModifyLibrary`, `discoveryAcknowledgementIsAccountScoped`, and `starterPackPinnedOrderIsPreserved`.
- [ ] Add an optional Choose feeds action on Finish, alongside the existing completion route. Present the shared discovery session and return to Finish on dismissal. Finishing remains possible without a save.
- [ ] Explain Saved and Pinned on the first successful add with a dismissible, concise message. Update the existing plus-button instructional copy to match the entry option chosen in Task 3.
- [ ] Do not auto-subscribe from selected interests and do not advertise recommendations until relevance is validated. Keep the initial browse source and labels from Task 2.
- [ ] Verify new-account, returning-account, skip, account-switch and starter-pack cases. Seal and immediately run jj new.

### Task 5: Integration and final evidence

**Files:** Update the implementation evidence note under `docs/session-notes/`; no unrelated cleanup or generated-file changes.

- [ ] Coordinate a quiet build window with the integration owner. Inspect current canonical content and apply only reviewed diffs; preserve newer changes in each shared file.
- [ ] Build the final app once, then run the affected journey on compact and large phones. Confirm native search and reordering from the previous batch still work, the banner remains visible below controls, and the Circles account gate is retained.
- [ ] Capture screenshots for browse/results, long-description preview, saved confirmation and the normal start-page entry. Record runtime save/reopen evidence separately from fake transport tests; include failed receipts and any remaining limits.
- [ ] Report exact source identity, test outcomes and runtime coverage. Do not call a successful compile, fixture render or local preference write a complete real-account journey.

## Review checklist

- [x] Permanent entry and its alternative are concrete; placement remains a review decision.
- [x] Local library search is distinct from discovering new feeds.
- [x] Browse, search, preview, add, pin, open and failure behavior are specified.
- [x] Onboarding reuses the same flow without forced replay or auto-adds.
- [x] URI identity, cancellation, paging and persistence failure have explicit tests.
- [x] Existing banner/native controls/Circles gate and current phone-build isolation are retained.
