# Support tip implementation and verification

Catbird's support screen now offers the existing four optional one-time tips with actionable loading failures. Purchase verification and completion live in a shared service, so leaving Settings no longer stops the transaction listener. This source starts from the sealed Lite candidate `f0ca2f5334ac87fd53ac30f50861f296576c8051` and does not include feature-subtraction or dependency edits. Integration owns the app-start hook, combined app build, simulator captures, scheme/test membership, and physical-device qualification.

Governing [implementation plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md); [owned decisions](support-tip-decisions.md).

## Changed behavior

- `SupportTipStore` owns product loading, purchase progress, verified transaction finishing, startup unfinished transactions, ongoing updates, and storefront reloads. The injectable `SupportTipClient` supports deterministic tests without purchases.
- About uses the exact requested heading/copy: “Support Catbird”, “Leave an optional tip to support Catbird's development.” and “Thanks for your support!” on success. Tip labels/prices come from StoreKit. Rows adapt horizontally or vertically for large text.
- TestFlight/review uses the same visible section. Empty and failed catalogs expose Try Again and pull-to-refresh; no subscription/restore/manage UI remains.
- The existing local StoreKit catalog now uses Xcode's native version-4 keys. All six original public IDs and amounts are preserved; only four consumables are requested by the app.

## Integration seams

Call `SupportTipStore.shared.start()` once from `CatbirdApp.init()` on the main actor. This call is synchronous and idempotent; About also starts the service defensively when loading. Do not stop it on scene deactivation, Settings dismissal, or Bluesky account changes.

Source and tests live in synchronized folders. Ensure `SupportTipStoreTests.swift` and `SupportTipStoreKitTests.swift` belong to the retained test target, and `SupportCatbird.storekit` is available in the host application's bundle for `SKTestSession(configurationFileNamed: "SupportCatbird")`. Select the file in the local Run scheme for manual StoreKit UI verification. Keep that testing configuration separate from App Store release execution.

For a DEBUG fixture, `AboutSettingsView(supportStore:)` accepts an isolated service with a fixture client. No production launch-argument override or fake shared singleton is present.

## Evidence so far

- PASS: production service type-checks with the installed iOS 27 SDK, iOS 18 deployment target, and explicit Swift 6 language mode.
- PASS: About source parses; scoped SwiftLint completes with zero warnings/errors.
- PASS: deterministic `SupportTipStoreTests` executed against copied exact service/test files in an isolated macOS SwiftPM harness: 11 tests, zero failures. Covers empty/failed catalog retry, allowlist/sorting, success/repeat, cancel/error/retry, delayed approval via updates without About, launch unfinished reconciliation/idempotent start, duplicate transaction delivery, unverified/unrelated transactions, storefront reload, stale-product rejection, and cancellation/reentry while product loading is suspended.
- PASS: both test files type-check against the iOS simulator SDK and StoreKitTest/Testing frameworks with Swift 6.
- PASS: a conversion assertion compared every original product ID/decimal price to the repaired catalog; all six matched.
- REVIEW: independent source review found cancellation/reentry could strand an empty About screen. The loader now runs in a store-owned task, new callers await that task, and an unexpected client cancellation exposes retry. The suspended-load regression passes.
- PENDING: `SupportTipStoreKitTests/localCatalogAndPurchaseLifecycle` on the dedicated simulator. The test first injects a local product-loading failure and requires interception before exercising purchases; it then covers catalog load, success, repeat, cancel, errors, unavailable purchase, Ask to Buy completion with no About screen, and empty unfinished transactions.
- PENDING: combined Lite/full compilation, running About with ordinary/accessibility text, unavailable/retry screenshots, and authenticated device behavior. Fixture evidence is not physical-device qualification.

Raw fixture test output: [test.log](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-unit-harness/test.log). The isolated harness and standalone typecheck outputs are outside iCloud under `/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/`. No production action, live purchase, App Store Connect mutation, or user-preference reset was performed.

## Local StoreKit startup ordering

The first hosted lifecycle run stopped at the required error-interception check before any purchase. Its archived logs show the app's startup transaction listener opening a Sandbox client before `SKTestSession` saved the local configuration. The session then accepted the injected product-loading error, while product requests still used Sandbox. This establishes an environment mismatch; a fresh run must determine whether the startup ordering change resolves it.

The dedicated DEBUG iOS simulator launch argument `--support-tip-storekit-test` defers only the `SupportTipStore.shared.start()` call in `CatbirdApp.init()`. All other launches, Release builds, devices, and macOS retain normal startup. The test requires both this argument and `--scene-runtime-ui-fixture` before creating a session, prepares and retains `SKTestSession`, then explicitly starts the same app-owned singleton. No StoreKitTest framework is imported into the app, and the service, product catalog, signed-transaction handling, and purchase assertions are unchanged.

The product-error interception requirement remains the first purchase gate. This test now verifies the singleton listener after explicit test-session setup; it does not independently qualify the ordinary app-launch hook. Keep the separate normal-startup evidence boundary visible when reporting results.

- Previous failed run: `/Users/joshlacalamito/Developer/_settings-feedback-builds/combined-r4/08/Tests.xcresult` and `raw.log` in the same directory.
- Exported runtime evidence: `/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-selector8-runtime.log`; startup Sandbox requests at lines 26–45, saved local configuration at lines 66–108, injected error plus Sandbox product request at lines 312–341, and subsequent Sandbox Media API request at lines 473–480.
- Focused validation: `/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-ordering-typecheck/validation.log`; the exact service module and updated lifecycle test type-check in Swift 6 against the iOS simulator SDK, and both app startup files parse. This is not a simulator execution or a full app build.
- Next runtime gate: rebuild the affected app/test products and run only `CatbirdTests/SupportTipStoreKitTests/localCatalogAndPurchaseLifecycle` on the dedicated local simulator, serially, with both arguments above. Retain the fail-closed check and inspect XcodeTest versus Sandbox request context if it fails again. Frozen prior inputs and products are unchanged.

Governing plan: [parallel feedback execution](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md). The integration owner controls the next combined build and runtime slot.
