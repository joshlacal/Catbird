# Settings, optional support, and shared typography

This lane addresses confusing Settings organization, incomplete optional tipping, and shared text that ignored the user's font preferences. The Lite candidate now keeps its native Forms while consolidating duplicate editors, correcting misleading or unsupported controls, and exposing recoverable preference-storage failures. The tip service owns transaction handling for the application lifetime, and eight shared typography helpers now honor the existing font manager. Focused checks have passed, but full-app builds, Settings screenshots, local StoreKit transactions, and authenticated device behavior remain separate qualification gates.

Governing [parallel execution plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md), [live feedback LITE-004/009/010](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/qa/catbird-lite-live-feedback.md), and [release plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-09-29-catbird-1.0-app-store-plan.md). Provisional choices are recorded in [Settings decisions](settings-decisions.md), [support decisions](support-tip-decisions.md), and the [design rules](settings-design-rules.md#provisional-decisions-for-integration); integration owns their append-only consolidation into the workspace decision log.

## Candidate and ownership

- Combined Lite source: `58d599569d9b7482033628e388d9e65432713868`, based on `f0ca2f5334ac87fd53ac30f50861f296576c8051`. All lane-owned work is sealed in isolated jj workspaces; the canonical working copy was not edited.
- Final Lite test source: `6fd712860cb88649ed858317597d49153bed359b`; production code matches `58d59956`. It strengthens pending-value and actual-landscape assertions, and includes the handoff document.
- Settings persistence delta: `adf6631969a8cd547cc847a4f174420f5278c592`. The earlier inventory and complete control dispositions are in [the control audit](settings-control-audit.md).
- Full Catbird source is sealed at `fd3a084289ec278a54599da69793edc4eb579fb2`, rooted in `d0957b4cb885466807f940ab8e090fce75674567`. Documentation inventory `19f52fc76a737895e5ad2fcfc3d6dc3a23b747cc` contains the [Full counterpart report](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/settings-full/docs/settings-full-counterpart.md). It preserves encrypted-messaging routes, sensitive-image scanning and all 43 fields including message retention. Retention effects wait for durable save, coalesce, and check the active account, instance and final value. The Full chain contains no Lite ancestry.
- Integration owns combined app/dependency inputs, project/scheme conflicts, notification-consumer corrections, physical-device installation, and authenticated acceptance. This lane owns the Settings source, StoreKit service, shared typography change, fixture/tests, and their evidence.

The isolated fallback simulator copy is [Inputs/Catbird](/Users/joshlacalamito/Developer/_settings-feedback-builds/Inputs/Catbird). [The build manifest](/Users/joshlacalamito/Developer/_settings-feedback-builds/Evidence/build-manifest.json) selects Petrel `329b5fbe412286ff4c094246b6f30c2989e58f94` and PetrelCatbird `ff98deedc748777537f912fa4dcd208f9bbc840e`. All 987 tracked Catbird files were copied and hash-compared to the clean source; [the exact file receipt](/Users/joshlacalamito/Developer/_settings-feedback-builds/Evidence/source-58d599569d9b7482033628e388d9e65432713868.json) preserves those hashes. The Lite lockfile retains its graph: shared remote dependency pins match the frozen Full graph, with the Full-only SQLCipher package absent.

Integration accepted reuse of its upcoming combined build-for-testing products. Their exact integrated source/dependency manifest, app/test-bundle hashes and `.xctestrun` identity must accompany the runtime evidence. The earlier isolated `58d59956` file receipt is only the fallback source copy and must not be used to attribute the later combined binary. No combined binary has been tested by this lane yet.

## Resulting behavior

### Settings

Settings groups account, content, appearance/accessibility, notifications, and support by task. Appearance owns custom typography; Accessibility owns system text scaling; Content & Media owns autoplay; Moderation owns account safety. Cross-links replace duplicate editors. Appearance reset now asks for confirmation and changes only theme, dark appearance, accent and custom typography, preserving accessibility, language, media, account and provider-consent values.

Lite no longer presents controls without a retained consumer, including encrypted-chat scanning, long-press duration, the misleading Shake to Undo switch, and unused thread prioritization. Stored preference keys remain intact. Empty labeler lists still expose Add Labeler, and the enabled-filter summary includes filters that are enabled by default.

Account preferences require an authenticated refresh, expose failure/retry, and retain a failed write for retry. Interest changes use the server-first writer and can explicitly clear all tags. Language copy describes local scope; immediate selections close with Done. The labeler-header completion event is emitted only after applying the request header and carries the captured account DID and applied labeler list for the social lane's consumer.

Local settings use a private SwiftData context and detached confirmed/draft values. Failed loading disables dependent local controls while leaving account and support navigation available. Failed saving restores the confirmed values and retains the attempted changes for Retry Saving. Retries apply only changed fields to the latest stored row, preserving concurrent unrelated edits and per-provider consent. Account/generation checks prevent stale saves or global effects; failed writes emit neither successful-change events nor backups. Retry Loading can refresh confirmed runtime values while a failed draft still awaits its separate Retry Saving action. Pending drafts are in memory and do not survive app termination; the UI states this limitation.

### Optional support

The About Form uses the requested friendly support copy and localized product labels/prices. The application-owned, idempotently started `SupportTipStore` handles loading, verification, finishing, unfinished transactions, delayed updates and storefront changes. Only the four existing one-time consumables are requested. No new product ID, price, recurring billing, or App Store Connect change is introduced. Empty/failed catalogs provide retry; the TestFlight distribution gate no longer hides the section. See [the support implementation report](support-tip-implementation.md) for the service seam and complete test coverage.

### Shared typography and layout rules

Eight named typography helpers preserve their original base sizes and weights while using the existing preference-aware font manager. The change reaches 67 calls across Messages and Muted Words. The standalone fixed-size decorative helper is unchanged. Feed/notification/search-result boundaries remain full-width, the Messages inbox keeps native insets, discovery uses section hierarchy, and native Forms keep system row metrics. [The design audit](settings-design-rules.md) maps the concrete components and screen-owner checks.

## Verification ledger

| Evidence | Current result | Boundary |
| --- | --- | --- |
| Production settings persistence code in isolated host fixture | 12 tests / 15 scenarios pass, plus fixture smoke | SwiftData/model and failure semantics; not an app/device action test |
| Full production settings persistence in isolated host fixture | 14 tests / 18 scenarios pass; 27 changed Swift files parse | All 43 fields and retention effect orchestration; stubs replace production lifecycle/MLS execution |
| Appearance reset and reply-threshold helper fixture | Three focused tests pass | Model/pure helper; not a rendered confirmation |
| StoreKit service with deterministic local client | 11 tests pass; Swift 6 typecheck passes | Mock transaction/lifecycle behavior; not SKTestSession or App Store sandbox |
| Production typography component simulator | 80 preference assertions plus 32 cross-launch assertions pass | Three production source files in a component executable |
| Typography baseline negative control | Fails the expected ignored-font-size check | Confirms the test distinguishes the old behavior |
| Swift parsing and scoped lint | Parse passes; lint exits zero, with persistence size/style warnings | No full-app compile claim |
| AppState runtime propagation tests | Prepared; not run | Consecutive accent edits and recovered typography |
| Production Form layout suite | Prepared; not run | 26 container/screen combinations, screenshots and geometry |
| UI journeys | Prepared; not run | Nine local fixture journeys, including both storage failures |
| Local StoreKit transaction suite | Prepared; not run | Must first prove local interception before purchasing |
| Authenticated changes, relaunch/account switch, phone | Not run by this lane | Integration owns device and live-account acceptance |

Raw evidence: [Full persistence test log](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/settings-persistence-full-check/test-full-final.log), [persistence test log](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/settings-persistence-check/test.log), [StoreKit mock test log](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-unit-harness/test.log), and [typography evidence directory](/Users/joshlacalamito/Developer/_catbird-settings-evidence/typography). The typography report links the exact images, categories, compiled-source hashes and negative control. Actual system categories were Large and Accessibility XXXL; the component evidence does not establish production Form clipping, scene resize continuity or authenticated Messages behavior.

The isolated SwiftData fixtures explicitly disable CloudKit, including persistence, interest and AppState tests. This prevents the signed application host's CloudKit entitlements from changing the behavior of intended memory-only stores. The simulator category precondition is test-only; production FontManager and UIFontMetrics code remain unchanged.

## Remaining acceptance sequence

1. Receive integration's immutable combined Lite app/test products and exact source/dependency manifest. Record hashes of the `.xctestrun`, app, test bundles and manifest before running them; verify the Settings source/test revisions. Obtain an explicit test slot from integration and use the dedicated simulator `A37026BF-E9CC-4E69-AD2F-3425D737E09A`. Build with at most two compiler jobs and no overlapping lane compiler process.
2. Reuse those prepared products without another full build. The isolated snapshot is a fallback only if integration explicitly assigns that build. Verify the resulting app contains `SupportCatbird.storekit` and run the settings model, runtime propagation, deterministic tip and interest suites serially. Preserve logs and result bundles.
3. Run the 26 hosted layout combinations and nine UI journeys. Run the two hosted methods in separate fresh processes: `testSettingsFormsFitReceivingContainersAndReachTheirLastRow` with simulator `content_size large`, and `testAboutCatalogAndRetryFitLargeTextWithAsymmetricSafeAreas` with `content_size accessibility-extra-large`. Restore Large afterward. The tests require both UIApplication and the fixture FontManager cache category to match the requested category before rendering; a host-only trait override cannot satisfy this gate. Export screenshots/geometry, inspect text and final-row reachability, and verify actual UIKit text-size categories. The fixture uses production Forms, isolated memory storage and a loopback unauthenticated client. Direct About launches use a fake tip catalog; root-to-About navigation uses the shared production store but never selects a purchase. The app-start listener may perform read-only StoreKit reconciliation. The server-unavailable journey verifies presentation and a usable retry control, not successful remote recovery.
4. Run `SupportTipStoreKitTests/localCatalogAndPurchaseLifecycle` on the dedicated simulator. The test requires an injected local product-loading error before any purchase; then verify repeated tips, cancellation, failure, unavailable product and delayed approval with no About view. No real purchase is authorized or necessary.
5. Integrate the sealed Full counterpart without Lite feature subtraction and run the combined app gates with the notification fixes. Use integration's phone session to verify relevant preference effects, persistence, account boundaries and representative retained screens. Keep every control without runtime evidence explicitly unresolved in the audit.

Notification master-registration, server/local direct-message toggle reconciliation and the in-app notification predicate were escalated to integration's assigned owner. This lane's audit does not claim those consumers are repaired. The old About global-first-window subscription presenter was removed by the tips-only change; no extra fix is needed for that deleted action. Whole-app scene routing and resize continuity remain integration work.

No production service, real purchase, App Store configuration, real account preference or physical-device installation was changed by this lane.
