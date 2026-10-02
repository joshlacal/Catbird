# Support tip decisions

Catbird's About screen already offered support purchases, but its listener stopped when the screen disappeared. This work makes tip completion an application responsibility and keeps the release's four one-time consumables visible in every distribution. The product identifiers and catalog amounts remain unchanged. Local fixture tests establish service behavior; a dedicated StoreKit simulator run and integration's running-app capture remain separate qualification gates.

Governing scope: [parallel implementation plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md), [release plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-09-29-catbird-1.0-app-store-plan.md), and [feedback LITE-009](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/qa/catbird-lite-live-feedback.md).

## Application-owned tip lifecycle

Chose: one main-actor observable `SupportTipStore.shared` (provisional), started from `CatbirdApp.init`, with an injectable StoreKit client. Because: purchase status belongs to the UI, but transaction completion must outlive the About screen and begin at app launch. Rejected: an About-bound `.task` listener because dismissal cancels pending completion; an account-bound store because tips belong to the App Store account rather than a Bluesky account. Reversible until: merge of the feedback candidate. Override by: replace the app-start ownership hook and injected service while preserving the tested lifecycle contract.

The service starts `Transaction.updates`, reconciles `Transaction.unfinished`, and watches storefront changes. It finishes only verified consumables in the existing four-tip allowlist; unrelated and unverified purchases are left for their proper owner. Delivery from purchase, updates, and startup reconciliation is deduplicated by transaction identifier before any suspension. Successful consumable tips grant no entitlement or account state, so finishing follows verification directly. Screen dismissal does not cancel observers or the shared, awaited product-loading task. The service cancels its streams on deinitialization.

## Tips-only support presentation

Chose: all builds show the same Support Catbird section with four existing consumables, friendly optional-tip copy, retry, and pull-to-refresh. Because: the release plan's D4 chooses tips only, and distribution heuristics previously hid purchases in TestFlight/review. Rejected: repairing the receipt-based distribution heuristic because support has no reason to depend on distribution. Reversible until: merge of the feedback candidate. Override by: change the support presentation in About without changing the product catalog.

The section no longer offers recurring purchases, Restore Purchases, or subscription management. The existing recurring product definitions remain in the local catalog but are not queried or sold by this release. Product display names and prices come from StoreKit. No App Store Connect changes, price changes, live purchases, account mutation, or subscription migration are part of this work.

## Local catalog schema repair

Chose: repair the existing StoreKit file into native Xcode version-4 structure, preserving all public product IDs, decimal prices, recurring periods, settings, and localization text. Because: the previous `id`/`prices` shape was not the schema used by Xcode's StoreKit editor and test session. Rejected: inventing a new test-only catalog with different product identifiers. Reversible until: merge of the feedback candidate. Override by: export an equivalent native catalog from Xcode while preserving the approved public identifiers and amounts.

This is an editor/testing format repair, not a live catalog change. Four consumables stay in `products`; two recurring definitions move to `subscriptionGroups[].subscriptions`. Runtime loading still must verify the repaired file with `SKTestSession`.

Apple references: [Transaction updates](https://developer.apple.com/documentation/storekit/transaction/updates), [unfinished transactions](https://developer.apple.com/documentation/storekit/transaction/unfinished), [StoreKit configuration testing](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode), and [local error injection](https://developer.apple.com/documentation/storekittest/sktestsession/setsimulatederror(_:forapi:)).
