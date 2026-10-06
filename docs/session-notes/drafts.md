# Saved-post draft interoperability

Catbird's saved-post library now has opt-in, remote-first synchronization with the upstream Bluesky draft service. Existing local drafts remain durable, unsupported content stays local with an explanation, and remotely deleted or conflicting drafts retain a visible recovery copy. The sync implementation, composer restoration and publication seams, and tests are implemented in this isolated lane; the combined app build and simulator qualification are separate gates owned by integration. No account draft data was read or mutated and no post, message, reaction or appeal was sent.

Governing scope: [parallel execution](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md), [LITE-005](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/qa/catbird-lite-live-feedback.md), and [Lite release scope](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-09-29-catbird-1.0-app-store-plan.md).

## Provisional decisions for integration

- Keep synchronization opt-in. The Drafts sheet exposes the existing opt-in explicitly and describes upload behavior and app-install-local media. No ExperimentalSettings source/default changed. Reversible before merging by changing the owned Drafts sheet action and coordinating any settings default with the settings owner.
- Keep the existing SwiftData DraftPost model and add one optional Data attribute containing sync metadata. Baseline draft/remote bytes, pending creates, pre-create remote identities, recovery state and deletion intent share the durable row. No destructive local migration or new model registration. Reversible before merge by retaining the old service and omitting this attribute; do not remove already-persisted user content.
- Use Petrel's generated types for known lexicon validation/translation and a raw JSON envelope for remote properties generated structs cannot preserve. Only local projection changes patch the original envelope. This avoids hand-editing generated models. All requests retain standard Petrel authentication/routing and exact DID plus credential-generation continuity.
- Fetch every page before reconciliation. Empty advancing pages are followed, cursor cycles/nonterminating listings fail closed, and differing duplicates abort. Materialize remote drafts before outbound writes. Absence is not proof of deletion because upstream pagination is timestamp-based and nontransactional; preserve a local recovery copy and do not recreate the remote ID.
- Preserve conflicts as local recovery copies instead of timestamp-based last-write-wins. Read the remote draft again immediately before an update. Upstream has no atomic conditional update, so an unobserved edit in the final read/write window remains a protocol limitation; this is not a guarantee of lossless concurrent remote editing.
- Keep durable tombstones to suppress resurrection through failures/restarts; send deletion only when the completed listing still contains the ID. Tombstone rows retain recovery content and referenced local media rather than silently destroying the local library.
- Treat lost create responses as ambiguous. Record sent bytes and all pre-create remote IDs. Adopt only one new, unclaimed matching candidate, excluding IDs owned by another row and conflicting pending identical operations. Never blindly retry ambiguous creates. The explicit Save New Copy action warns about possible duplicate remote drafts and preserves the original local row.
- Persist stable local thread-entry identities so unknown remote post fields move with their post during reorder. Normalize legacy embedImages to gallery form only when media changes; removal cannot leave a stale legacy alias behind. Media references are usable only for this install and existing managed media paths, otherwise the list requires explicit Open Without Media.
- Snapshot account interaction defaults for legacy drafts before first upload; explicit saved rules, including unknown union cases and absent-versus-empty reply rules, survive both save and publication. Quotes retain URI and CID independently of preview hydration. Unresolved replies and legacy quotes without CID cannot silently publish as ordinary posts.

## Changed production files

- Core/Models/DraftPost.swift
- Features/Feed/Services/DraftPersistence.swift
- Features/Feed/Services/DraftSyncService.swift
- Features/Feed/Services/ComposerDraftManager.swift
- Features/Feed/Views/Components/PostComposer/DraftsListView.swift
- Features/Feed/Views/Components/PostComposer/PostComposerModels.swift
- Features/Feed/Views/Components/PostComposer/PostComposerViewModel.swift
- Features/Feed/Views/Components/PostComposer/PostComposerCore.swift

Paths are beneath Catbird/. New files under CatbirdTests/ use the project's synchronized membership: DraftSyncReconciliationTests.swift, DraftStoreMigrationTests.swift and PostComposerDraftRestorationTests.swift. Existing translation/captured-video lifecycle tests must also run.

## Verification evidence and limits

Swift frontend parsing passed for the changed production and test files. Eight executable checks passed against the actual extracted production envelope implementation: unknown object preservation, stable-identity reorder, legacy-media removal, unchanged legacy-media retention alt-text editing with unknown metadata, surviving-image metadata after gallery shrink, duplicate-reference isolation and replacement isolation. Harness source is retained outside iCloud in `/Users/joshlacalamito/Developer/_catbird-live-feedback-builds/social/drafts-checks/main.swift`.

The new app tests cover pagination beyond 500 rows, empty intermediate pages, cursor cycles, failed initial downloads, failed/local/remote deletions, conflicts, edits during requests, active account changes and cancellation generations, ambiguous create response recovery, rejection retry, pending identical drafts and multiple matching candidates, account-scoped persistence, interaction defaults, quote restoration/publication and raw envelope media semantics. The migration test writes an on-disk store with the previously shipped DraftPost schema (without the new attribute), reopens it with the current schema, and checks original data bytes, identity, timestamps and decoding. These tests are written and parse; passing execution must be recorded from the combined simulator test run.

No authenticated cross-app behavior or physical-device result is claimed. Root owns runtime fixture/screenshots and integration owns phone installation. AppView limitations remain: device/app-install-local media, no reply representation in saved draft schema, no CAS token for atomic concurrent update, timestamp cursor ties and no idempotency key for create. Unsupported replies, oversized text/threads/languages, GIF-provider state and outline tags stay local rather than being truncated or dropped.

## Full counterpart

Focused draft hunks are ported into the isolated Full/Catbird workspace. Full-only destination selection, circle reply locking, Circle service, submission destination state and public-only thread restrictions are retained. Quote publication helpers and added pending-reference validation apply only to public posting in Full. No Lite feature-subtraction history was imported.

The final media review adds unique localRef identity matching for gallery count/order changes; duplicated references and replacement files never inherit arbitrary old metadata. Same-install missing files now block replacement of preserved remote media just like foreign-app attachments. The reconciliation suite contains 30 tests, alongside 11 composer tests and the on-disk migration test. App execution remains pending the combined build slot.

Independent narrow source review found no new blocking media issues after the unique-reference and missing-file fixes; Lite and Full service/test bytes matched. It noted a conservative safe limitation: adding a text-only thread entry to a draft with unavailable media may require a new copy because its per-entry media-array structure changes. No independent app build was claimed.
