# Feed discovery implementation evidence

This change makes feed discovery visible from the start page and keeps search, preview, save, pin and explicit open in one journey. It also adds optional feed choice at onboarding Finish without changing existing progress indices. The user approved the full proposal and later requested native-search/banner corrections and removal of the unavailable Circles placeholder. Implementation is isolated; the integration owner controls serial app builds and runtime validation. No new phone install, push or deploy was performed.

Governing plan: [implementation plan](../../superpowers/plans/feed-discovery-experience.md). Decisions: [native placement and durable pending intents](../../DECISIONS.md).

## Evidence established

- Actual installed first-batch phone screenshot: feed-start-phone-before.png, captured read-only from iPhone Mirroring. Visible broad muted top band with Search your feeds; distinct transition to sharp artwork; disabled Circles placeholder. One still does not prove movement during activation.
- Production banner helper: native macOS SwiftUI ImageRenderer comparisons at widths320/440, insets96/110; actual helper typechecked against iOS18 deployment. These are fixture comparisons, not updated phone/runtime proof.
- Twenty-three actual library-action test bodies executed in a Swift6 extracted harness, with minimal Preferences/URI substitutes and actual UserDefaults pending store. Covers preservation/idempotence/order/errors/concurrency, pending retry/recreation/server-list reconciliation/account isolation/revision completion, legacy remove/unpin supersession, fresh-server metadata/order merging and V1 Following migration. Observation/AppState glue, SwiftData and network adapter are not exercised.
- Eight actual discovery model tests passed in a standalone Swift6 package with minimal Petrel boundary stubs. Covers stale query/account response rejection, clearing, deduplicated paging and preserved results/retry. Production provider and app UI are not exercised.
- Education helper account-isolation/recreation test passed with actual Foundation/UserDefaults helper.
- Swift source parsing passes. SwiftLint targeted new files reports warnings, no errors (view/action complexity and style). New app test-target tests and UI entry test are authored, not yet executed.

## Runtime/build gate

Integration task 01a09aa7-6232-76c2-bc59-568ec2dd00a1 owns the serial build after its current simulator launch diagnosis. Do not infer a final build from isolated checks. Apply the reviewed source diff atop the integrated1366e93b fix; preserve the owner's same Circles-placeholder removal and other current work.

Run app unit suites FeedLibraryActionsTests, FeedDiscoveryViewModelTests and FeedDiscoveryOnboardingTests, plus FeedDiscoveryJourneyTests using the existing fixture. That fixture covers normal-mode entry/native search/close only: it does not stub discovery transport or authenticated preference writes.

Manual runtime recipe on a permitted simulator/test account:
1. Open feed selector normally: Add Feed visible; unsupported/not-enabled Circles absent. Confirm toolbar native Search your feeds at rest/activation/scroll, stable visible sharp banner and colorful upward blend. Compare compact/large, RTL, larger text, Reduce Transparency.
2. Enter an unmatched local query; Discover more feeds explicitly carries it into remote search. Browse Popular, type/change/clear quickly, paginate, retry loading failure.
3. Preview a result, inspect complete description, navigate Back: preserve query/results/scroll. Open feed explicitly selects/exits. Ordinary Save leaves current/default feed unchanged and discovery open.
4. Save, repeat save, pin: verify Saved/Pinned labels, confirmation, default/order preservation. Simulate sync failure: visible pending state, then reopen account/retry and confirm server persistence. Verify explicit Remove retries removal.
5. Onboarding Finish: Choose feeds then Close returns to Finish; Start Exploring still works without choosing. Returning completed account does not replay; account-scoped explanation acknowledgment does not transfer; starter-pack pins keep order.

## Remaining limits

Full app compilation and updated UI/account runtime are pending. The manager's fetch/write revision guard is source-reviewed but not network/SwiftData exercised. UserDefaults intent storage and SwiftData are not one crash-atomic transaction. Existing unrelated whole-preference writers remain outside discovery serialization. No new image proves corrected native search placement on phone.

Integration review corrections: legacy successful writes acknowledge exact pending revisions, so completed intent cannot override a later remote re-add. Feed-specific synchronization retains unknown preferences and existing feed IDs/types; newly pinned records cannot displace the default even with mixed V2 ordering. Same-account client replacement invalidates discovery requests by client identity. Preview metadata is shared through an observable reference read inside the retained UIKit header host.

Empty-server onboarding guard: the feed-specific merge ensures Following exists before Save/Pin intents, so the first chosen feed cannot silently become the default. Regression checks cover empty library Save/Pin and preserving an existing default when adding missing Following.
