# Settings implementation decisions

This lane repairs the retained Catbird Lite Settings controls and their persistence boundaries. It keeps native Form presentation and preserves the user's existing account data and stored preference keys. The choices below are provisional product organization decisions for integration review. Build and running-app verification belong to the combined settings/support lane before completion is claimed.

Governing scope: [parallel implementation plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md), [Lite release plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-09-29-catbird-1.0-app-store-plan.md), and [feedback](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/qa/catbird-lite-live-feedback.md). This owned file is queued for the integration owner's append-only decision log.

## Group controls by user intent

Chose: keep Form and group account, content, display/accessibility, notifications, and help/support. Typography edits live in Appearance; system text scaling lives in Accessibility; autoplay lives in Content & Media; blocking/muting lives in Moderation. Cross-links replace duplicate editors. Rejected: multiple copies of the same editor, because they suggest independent settings. Reversible until: integration merge. Override by: move the relevant NavigationLink or control without migrating keys.

## Scope Appearance reset to visual customization

Chose: reset theme, dark-mode style, accent, and custom typography only, after confirmation. Preserve Dynamic Type and every accessibility, privacy, content/media, language, account, and provider-consent value. App icon is explicitly preserved. Removed Content & Media's mixed reset because it silently changed remote account filters and external-player consent together. Reversible until: integration merge. Override by: expose a separately scoped, confirmed reset with its own tested persistence contract.

## Hide controls without a supported Lite consumer

Chose: hide sensitive-content scanning, long-press duration, Shake to Undo, and Prioritize Users I Follow while preserving keys. Scanning/duration have no Lite consumer; Shake to Undo controls an error animation rather than device undo; prioritization is neither emitted by thread preference serialization nor used by local sorting. Rejected: keeping promises the app cannot fulfill. Full-app counterpart must retain its real MLS scanning feature if its consumer is present. Reversible until: integration merge. Override by: restore a control once its consumer is implemented and verified.

## Distinguish omitted thresholds from explicit clearing

Chose: add default-false clearReplyLikeThreshold to PreferencesManager.setFeedViewPreferences. Existing callers preserve their nil-means-unchanged contract; the Settings OFF action explicitly clears the threshold. The exact pure preference-update helper is tested for omission, clearing, reenabling, zero, and unrelated-field preservation. Rejected: changing nil semantics globally, because unrelated callers may omit the field intentionally. Reversible until: integration merge. Override by: use an explicit replacement API and reconcile every caller.

## Make account preference failures explicit

Chose: initial account controls require an authenticated remote refresh; local-only controls remain available during errors. Programmatic loading no longer triggers writes. A failed save retains its selected draft and retry operation, locks further synced edits, and retries that write rather than treating a local optimistic cache reload as server success. No real server writes were used in verification. Reversible until: integration merge. Override by: replace this with an account-scoped pending-write service with equivalent preservation/retry tests.

## Preserve interests until the server accepts an explicit change

Chose: use the existing server-first specific-preference writer for interest add, remove, and replace. The canonical actor lexicon permits an empty tags array, so clearing all interests sends an explicit empty InterestsPref. Add/remove transform the latest server snapshot, while local values change only after a successful write. A narrow injected transport permits real manager/SwiftData tests with local read/write fixtures. Rejected: changing the broad preference serializer, which could affect unrelated callers and preference types. Reversible until: integration merge. Override by: substitute an equivalent typed account-preference writer preserving this ordering and empty-list contract.

## Describe local language preferences honestly

Chose: describe Primary Language as this account's choice in Catbird on this device; the current serializer does not establish cross-app language synchronization. The content-language sheet saves selections immediately, so its dismissal says Done rather than Cancel. Rejected: claiming unsupported server behavior or implying Cancel rolls back applied choices. Reversible until: integration merge. Override by: implement verified language synchronization or a transactional draft editor and update copy to match.

## Notify consumers after labeler headers are applied

Chose: expose PreferencesManager.acceptLabelersHeaderDidChange with the manager object, account DID captured before the await, and applied labeler DIDs, emitted only after setAcceptLabelers completes. The social/profile owner filters both manager and account before reloading labels. Rejected: reloading from an early subscription-array observation, which can race request-header application. Reversible until: integration merge. Override by: replace with an equivalent typed post-application event. No new moderation policy, provider, or remote write is introduced.

## Preserve actions in empty states and count actual filters

Chose: expose Add Labeler independently of whether subscribed services return any rows, and derive the Settings filter badge from actual isEnabled values so the default duplicate filter counts. Rejected: treating empty subscriptions as lack of an add capability or treating stored active IDs as the sole runtime filter state. Reversible until: integration merge. Override by: change the display policy with equivalent empty-state and default-state behavior.
