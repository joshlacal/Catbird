# Feed discovery experience proposal

Status: approved for isolated implementation. The user selected the always-visible Add Feed row and approved the complete discovery flow. Runtime verification remains pending; no new phone install, push, or deploy is authorized.

Catbird currently makes people enter edit mode before they can discover another feed. Once they arrive, discovery uses a separate search field, a nested preview sheet, and a subscription toggle that can remove a feed immediately. This proposal makes finding and saving a feed a visible, understandable journey while preserving the existing large icons, Liquid Glass controls, native navigation, and feed-start banner. The approved entry is the labeled Add Feed row; full app/runtime validation is coordinated separately.

The governing request is originating task `01a09a9e-4459-71d1-8360-c9fe62743ee2`, delegated to feed task `01a09ab6-9969-7832-8384-89c12bf28c47`. The two authorized bug fixes—description wrapping and icon-relative delete badges—are isolated separately. This proposal does not authorize a wholesale start-page redesign, heading removal, typography overhaul, or canonical integration.

## What the source establishes

| Surface | Current behavior | Consequence |
| --- | --- | --- |
| `FeedsStartPage.feedsContent` | `addFeedButton()` is inside `if isEditingFeeds` | Adding looks like a maintenance task hidden behind the pencil. |
| Start-page native search | Filters existing pinned/saved feeds | It cannot find an unfamiliar feed; this distinction needs clear copy. |
| `AddFeedSheet` | Custom TextField; search fires on submit; requests up to 20 popular generators with optional query | No paging; no request identity check to reject old query results. Global loading replaces content. |
| `AddFeedSheet.feedsGrid` | Shared header row previews a feed in another sheet and directly toggles membership | A checkmark can immediately remove a saved feed. Errors are logged without visible feedback. |
| `AddFeedSheet.pinConfirmationSheet` | Declaration exists, but no assignment presents a selected feed | The pin-choice confirmation is not the active add flow. It should not define the proposed journey. |
| `FeedDiscoveryHeaderView` | Description explicitly limited to two lines | Same cutoff appears in Add Feed, global feed search, and an open feed header. |
| `SmartFeedDiscoveryView` and card deck | Only preview/commented entry points found | Their existence is not evidence of an integrated or validated discovery journey. |
| `SmartFeedRecommendationEngine` | Uses interests/description matching and popularity among candidates | Do not promise authoritative topic categories or time-based trending from these heuristics. |
| `WelcomeOnboardingView` | Avatar → Interests → Suggested Accounts → Finish; progress stored as integer 0–3 | A new inserted step would need migration. Current interests copy promises feeds but offers no explicit feed-choice step. |
| `OnboardingModels.feedDiscovery` | Copy says to tap a plus button | That instruction does not match the normal start-page entry today. |

## Recommended entry point, with an alternative

**A — recommended: always-visible labeled “Add Feed” action.** Reuse the existing add action below the title/actions row and above the main feed card, but show it in normal browsing as well as edit mode. Use `Label("Add Feed", systemImage: "plus")`, a minimum 44-point target, and the existing rounded/glass treatment. This is the smallest navigation change, communicates its purpose without onboarding, and avoids adding a fourth circular icon to the crowded title row. Cost: one persistent row of vertical space. Do not implement placement until reviewed.

**B — compact alternative: plus in the title/actions row.** Keep an accessible localized “Add Feed” label, add a TipKit explanation on first use, and use an adaptive layout that moves secondary controls to a second row when they do not fit. This saves default-height vertical space but increases icon density and needs more care at accessibility text sizes. Do not silently remove the current search, layout, or edit actions to make room.

Both keep the visible Feeds heading for now. Heading removal, stronger grid typography, and Pinned/Saved group surfaces remain separate design choices. The empty-library state should independently offer the same labeled Add Feed action; existing users should not have to trigger onboarding to find it.

## Proposed journey

1. **Start:** people see their library and the visible Add Feed action. Native search here says “Search your feeds.” With no local matches, offer “Discover more feeds” carrying the query into discovery. This is an explicit transition, not a silent switch from local to network search.
2. **Browse:** Add Feed opens one Discover Feeds navigation sheet. It initially shows Popular feeds from the existing endpoint, with a native global search prompt “Search feeds.” Saved/pinned membership is visible per item. Do not call popularity “Trending.” Preserve the user's library and active timeline underneath the sheet.
3. **Search:** trimmed queries update after a short debounce, while submit runs immediately. Keep prior useful results visible during refresh. Preserve query and scroll position when visiting a result. Support cursor-based loading with an inline retry and no duplicate URIs. An explicit empty result explains the query and offers clearing it.
4. **Preview:** tapping the identity or description pushes the existing feed preview into this sheet's navigation stack. The Back action returns to the same results and position. The preview provides the full description, creator attribution, representative posts through the existing feed screen, and the same Add action as its source row. Close exits discovery; Back does not exit it.
5. **Add:** a deliberate Add action saves the feed to Saved without changing the current/default feed. Show a per-item progress state and disable repeat submission for that URI. On confirmed persistence, change the state to “Saved” and announce “Added to Saved.” Keep the discovery sheet open so people can choose more than one feed.
6. **Pin or open:** offer “Pin to start page” and “Open feed” after saving. Pinning is optional and preserves other pinned order; opening is the only action that changes the visible feed. Do not require a second confirmation sheet for every add. If a feed is already saved/pinned, show that state; tapping the state should reveal explicit manage actions instead of immediately removing it.
7. **Failure:** retain the result and user's intended destination; display a short inline message and Retry. Do not announce success or dismiss the sheet if persistence fails. A failed request must not leave the library in an unexplained half-applied state. Existing membership may be shown while a retry is pending, but pending and confirmed states must be distinct.
8. **Return:** Done returns to the start page with the added feed visible in its actual destination, preserving any existing default feed. Library state updates across preview, results, and the start page through the existing invalidation bus and URI identity.

## Onboarding integration

Keep the current four steps and their stored indices. Add an optional “Choose feeds” action to Finish, opening the same discovery sheet; “Start exploring” remains available without adding a feed. This avoids replaying onboarding for existing accounts or turning feed selection into a signup requirement. Explain Saved versus Pinned briefly at the first successful add, with a dismissible account-scoped acknowledgement.

If interests were selected, the first version still offers honest Popular browsing and search. A later independently reviewed increment may add “Suggested for your interests,” but only after validating recommendation relevance and displaying a real reason such as a matching selected topic. Do not substitute a raw interest string into search and call its results personalized. Do not auto-add feeds based on interest selection.

Reconcile the existing plus-button onboarding copy with the entry point chosen in review. Returning users get discoverability through the permanent action, not a reset of `hasCompletedWelcome`. Existing starter-pack pinning remains intact; discovery additions do not replace those feeds.

## State and persistence requirements

- Query, cursor, loading and error state belong to the presented discovery session and active account.
- Results from a previous query/account cannot replace current results. Cancellation alone is insufficient; compare captured request identity before applying a response.
- Use feed URI as identity throughout rows, preview, membership and deduplication.
- Load membership once per library snapshot rather than making one preference read per appearing row.
- Keep initial-load failure, refresh failure, paging failure and one-feed save failure separate. Retry the failed operation only.
- One shared save/pin operation must own membership writes for all discovery entry points. Preserve unrelated preference fields and concurrent changes. Return a throwing/result-bearing outcome rather than relying on the current ViewModel's swallowed error.
- No schema/code-generation or backend change is required for the proposed first version. Read the installed endpoint contract before relying on cursor or query behavior.
- Do not activate dormant card-deck or recommendation surfaces simply because they exist; consolidate the active AddFeedSheet flow first.

## Acceptance evidence required before calling it done

On compact and large phones, normal and accessibility text sizes, LTR and RTL: Add Feed is discoverable without edit mode; full description remains readable; controls do not overlap; preview/back restores search; save/pin/open have distinct outcomes; failure remains actionable; and an existing account can skip onboarding without losing its library. Verify a real account's successful add and persistence after reopening, plus deterministic tests for stale searches and persistence failure. Test older supported iOS behavior and Reduce Transparency. A fixture render or compile alone does not establish those interaction claims.

[Implementation plan](../superpowers/plans/feed-discovery-experience.md)
