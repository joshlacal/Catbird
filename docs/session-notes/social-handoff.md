# Social feedback implementation handoff

This change repairs saved-post drafts, profile labels and appeals, Germ links, and post sharing in Catbird Lite. A focused Full counterpart preserves Circle, encrypted-chat and other Full-only behavior. Implementation, independent source review, simulator compilation and the bounded offline feature checks are complete. Combined scene integration and authenticated phone behavior remain separate gates. No live post, message, reaction, appeal or account draft mutation was performed.

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

The app test source contains 30 reconciliation regressions, 11 composer restoration regressions, one real prior-schema on-disk migration regression, share/recipient/repost and label/Germ/appeal tests, six offline UI journeys, and a four-component rendered geometry matrix. Existing draft translation and captured-video lifecycle tests remain part of the coordinated test selection. Those tests were not yet executed at the first source handoff; the completed simulator results are recorded below.

## Offline runtime fixtures

`--social-actions-ui-fixture` bypasses account bootstrap and legacy working-draft restore. The saved-draft manager receives an in-memory model context with migration, account observation and network sync disabled. A localhost-only client, injected recipient transport, mock appeal result, and local Send counter exercise production views without authenticated mutations. The fixture is DEBUG-only. Full uses its existing rich embed and composer types.

The component harness resizes real label, profile, draft and recipient views through narrow, wide, short, tall, square and returned-narrow sizes, with accessibility text and asymmetric safe areas. It captures screenshots, SwiftUI/host geometry, OCR text and retained state. This is component evidence only; integration still owns whole-window scene continuity and physical-phone checks.

## Integration contracts and remaining gates

1. Include the Settings labeler notification publisher at Lite `743fd0ae2dc1bbee4cf93c88e4f9b12da39198f1` (and its focused Full counterpart). ProfileHeader consumes the exact preferences-manager identity, captured account DID and applied labeler DIDs after the request-header update; it never mutates that header itself.
2. The original feature source now builds and passes the bounded simulator checks below. Preserve the frozen dependency manifest when combining it with other lanes. Full used the matched arm64 simulator FFI input; device/macOS framework qualification remains separate.
3. Apply the separate [scene-owned draft/share follow-up](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social-scene/Catbird/docs/session-notes/scene-handoff.md) with integration's scene navigation, shell and lifecycle hooks. The original feature source tested here still uses baseline scene routing; its passing fixture results do not qualify simultaneous same-account/same-conversation windows.
4. The separate scene work replaces shared active-editor slots with editing claims, presentation leases and targeted account-switch envelopes while preserving account-owned storage. Execute its new tests and two-window/account-switch checks against the combined source before marking LITE-017 verified. Source-review findings and hook dependencies are recorded in that follow-up's report.
5. Integration alone installs the combined candidate on the phone and verifies actual labels, Germ cancellation, menu/More presentation, recipient staging and draft recovery behavior. The installed build 4 share sheet was observed eventually; the earlier capture was premature, so no baseline button failure or measured latency is claimed. See [baseline observation](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social/evidence/baseline-share-observation.md).

Protocol limits remain explicit: remote media belongs to its originating app/install; the upstream draft service has no atomic conditional-update token or create idempotency key; an unseen remote edit in the final reread/write interval cannot be excluded. Ambiguous operations stay recoverable rather than being blindly repeated. Authenticated cross-client draft synchronization and phone behavior are not qualified by local mocks.


## Completed offline simulator validation — October 2, 2026

The complete [runtime report](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social/evidence/runtime-validation-report.md) and [manifest](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social/evidence/runtime-validation-manifest.json) link process receipts, exact source/dependencies, xcresults, screenshots and surviving binary hashes. Both apps compiled with Xcode 27.0 and ran on the dedicated iOS 27.0 iPhone 17 Pro simulator. All processes finished and were reaped; the shared heavy build slot was released.

| Variant | Source and run | Executed outcome |
| --- | --- | --- |
| Lite | `47aa1728` feature/fixture source in `Lite-validation-r2`; UI corrections through `122848e1` in `Lite-ui-r3` and `2879c4251205a8f6954253456845c2b2a17dd82f` in `Lite-ui-r4` | All 105 focused tests, four component methods and six distinct UI journeys passed across these runs. The 115-test selection was not rerun as one all-green suite on the latest head. |
| Full | `32790e168577fae56447c9bcbb3b39da5912d508` in `Full-validation-r1` | 114/114 selected tests passed in one run: 104 focused, four component methods and six UI journeys; 121 expanded invocations, zero failures or skips. |

The focused suite includes saved-draft reconciliation, migration, restoration, media persistence, label/appeal/Germ policies, recipient selection, pending shares and repost failure behavior. Full preserves its richer shared-post preview; its one-preview identity test replaces two Lite preview tests, accounting for the one-test count difference. Each variant produced 24 measured component captures: four components across six sizes, with accessibility text, asymmetric safe areas and returned-narrow state retention.

Screenshots were inspected for readable label details, draft recovery and missing-media explanation, Germ confirmation/cancellation, recipient selection and staged post content. UI assertions verify the failed appeal retains its reason and no fixture message is sent merely by staging. The appeal screenshot's keyboard hides the error row, so error-message verification comes from XCTest rather than visible pixels. Existing profile count captions wrap within words at the narrow accessibility size; the matrix does not qualify the entire profile layout. Native More presentation/cancellation passed. Real account submissions, cross-install remote draft interoperability, complete window continuity and the phone remain unqualified.

Retained failed attempts explain the corrections: in-memory SwiftData tests now explicitly disable inferred CloudKit; UI selectors match iOS 27's multiline TextField and rendered Send button; fixture recipients explicitly permit incoming chat; and missing-media dismissal uses the current popover. These are test/fixture fixes, not evidence of real account failures. The earlier compiler corrections were limited to actor isolation and the awaited client network-service access. No production server, phone installation or authenticated account mutation occurred.
