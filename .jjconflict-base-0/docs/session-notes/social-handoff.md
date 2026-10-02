# Social feedback implementation handoff

This change repairs saved-post drafts, profile labels and appeals, Germ links, and post sharing in Catbird Lite. A focused Full counterpart preserves Circle, encrypted-chat and other Full-only behavior. Implementation and independent source review are complete; the first sealed source is ready for coordinated app compilation and simulator verification. No live post, message, reaction, appeal or account draft mutation was performed.

Governing plan: [parallel live-feedback execution](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md). Provisional decisions: [draft policy, sheet ownership, Germ projection and durable reconciliation](../DECISIONS.md). Exact source, dependencies and resulting build evidence are recorded under `/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social/evidence/`.

## Implemented behavior

- **LITE-005, saved-post drafts:** explicit opt-in synchronization downloads every remote page before writes, preserves unknown wire properties, carries quotes and interaction rules, preserves detected conflict/deletion recovery copies and persists unconfirmed create/delete intent. Existing SwiftData rows gain one optional metadata field. Local-only content and media from another installation remain clearly identified; missing local files cannot silently replace remote media. Details: [draft report](drafts.md).
- **LITE-007, profile labels:** own and other profiles show a count and detail entry for subscribed issuers, including informational labels. The inspector displays localized label definitions and issuer information. Only eligible own-account subjects can appeal, using the issuing labeler's DID service route. Cancellation and stale submissions cannot change a later attempt. Details: [profile report](profile.md).
- **LITE-008, Germ:** use the existing typed AppView projection, validate the message link, enforce documented visibility and owner-follows-viewer direction, and confirm intentional external handoff with viewer/profile identities. No automatic message occurs.
- **LITE-011, sharing:** the post action opens a menu for Bluesky chat, Copy Link and native More. SwiftUI owns its sheets. Recipient search/resolution guards the initiating account and exact authentication generation; staging preserves text/reply context and requires explicit final Send. Pending attachments are account/conversation keyed and replacement requires confirmation. Details: [sharing report](sharing.md).
- **Shared video action dependency:** failed repost operations restore the real prior URI and surface failure; missing record keys and non-2xx deletion responses do not report success. The video lane consumes these shared actions.

## Source review and checks before app execution

Independent review corrected encoded Germ paths, cancelled-appeal completion races, profile-record label filtering, macOS chat-menu routing, empty-page pagination, ambiguous create ownership, and legacy image alias removal. A later focused review corrected unknown metadata preservation when gallery count changes and handling of missing same-install media. The final extracted production envelope helper passed eight executable checks. The production appeal/notification helpers passed three compiled tests.

Swift syntax parsing passed for changed Lite and Full Swift sources. Lite scoped SwiftLint exited zero under repository configuration with warnings and no errors. These checks do not establish app compilation, rendering, remote interoperability or device behavior.

The app test source contains 30 reconciliation regressions, 11 composer restoration regressions, one real prior-schema on-disk migration regression, share/recipient/repost and label/Germ/appeal tests, six offline UI journeys, and a four-component rendered geometry matrix. Existing draft translation and captured-video lifecycle tests remain part of the coordinated test selection. The new tests have not yet executed in the first source handoff.

## Offline runtime fixtures

`--social-actions-ui-fixture` bypasses account bootstrap and legacy working-draft restore. The saved-draft manager receives an in-memory model context with migration, account observation and network sync disabled. A localhost-only client, injected recipient transport, mock appeal result, and local Send counter exercise production views without authenticated mutations. The fixture is DEBUG-only. Full uses its existing rich embed and composer types.

The component harness resizes real label, profile, draft and recipient views through narrow, wide, short, tall, square and returned-narrow sizes, with accessibility text and asymmetric safe areas. It captures screenshots, SwiftUI/host geometry, OCR text and retained state. This is component evidence only; integration still owns whole-window scene continuity and physical-phone checks.

## Integration contracts and remaining gates

1. Include the Settings labeler notification publisher at Lite `743fd0ae2dc1bbee4cf93c88e4f9b12da39198f1` (and its focused Full counterpart). ProfileHeader consumes the exact preferences-manager identity, captured account DID and applied labeler DIDs after the request-header update; it never mutates that header itself.
2. Build and run the focused app tests and offline UI journeys against the frozen dependency manifest; inspect screenshots and fix compiler/runtime findings. Full uses the matched arm64 simulator FFI input, not a complete device/macOS framework qualification.
3. Apply integration's scene navigation work after this handoff. `ShareToChatActivity.finishSelection` still uses the baseline navigation manager; the pending-share store needs originating scene identity or scene ownership before simultaneous same-account/same-conversation windows are qualified.
4. Implement the separately requested [composer scene audit](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social/evidence/composer-scene-audit.md) in a new workspace. Shared `currentDraft`/`restoredSavedDraftId` are not safe for independent windows; editing claims and targeted account-switch envelopes must protect autosave/save/clear while preserving account-owned storage. This audit did not change the reviewed synchronization contract.
5. Integration alone installs the combined candidate on the phone and verifies actual labels, Germ cancellation, menu/More presentation, recipient staging and draft recovery behavior. The installed build 4 share sheet was observed eventually; the earlier capture was premature, so no baseline button failure or measured latency is claimed. See [baseline observation](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social/evidence/baseline-share-observation.md).

Protocol limits remain explicit: remote media belongs to its originating app/install; the upstream draft service has no atomic conditional-update token or create idempotency key; an unseen remote edit in the final reread/write interval cannot be excluded. Ambiguous operations stay recoverable rather than being blindly repeated. Authenticated cross-client draft synchronization and phone behavior are not qualified by local mocks.
