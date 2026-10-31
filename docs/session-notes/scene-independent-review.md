# Independent review of the scene-owned composer boundary

The LITE-017 scene work separates each window's active composer from the account-owned saved-draft library. This review checked the implementation against the [earlier ownership audit](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social/evidence/composer-scene-audit.md), including delayed editor callbacks, saved-row conflict handling, account-transfer envelopes and focused Full preservation. All findings described below are repaired in the final inspected Lite and Full source, including the live-model snapshot provider and account-lifecycle recovery paths. No remaining P1/P2 was found in this bounded source review, and both variants are clear for source sealing. Complete-app integration, focused test execution and running-app qualification remain separate gates.

Governing scope: [parallel execution plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md). Integration decisions remain in [integration's decision log](/Users/joshlacalamito/Documents/Codex/2026-10-02/task/main-consolidation/WorkspaceDocs/docs/DECISIONS.md). This review did not make a new architecture decision or modify feature code.

## Evidence and inspected trees

- Lite: `/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social-scene/Catbird`.
- Full: `/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social-scene/Full/Catbird`.
- Focused composer/Full-sharing review was delegated independently; storage/session and baseline conflict repairs were reviewed directly.
- Final source comparison and hashes below were captured on 2026-10-02 at 22:11:56 UTC, after the owner's documentation-only rebase; Lite's final blank-line whitespace cleanup and resulting manager hash were rechecked at 22:13:09 UTC. The session, view-model and manager bytes match the reviewed source; these hashes identify that source without taking a VCS snapshot of another actor's work.
- Tests were read, not run. This reviewer ran no build, parser, Xcode test, simulator, device, network mutation or VCS mutation. Owner-reported parser checks are not presented as independent execution evidence.
- The running app used by the parent is built from the frozen original social source. It does not qualify this separate scene implementation.

## Findings and verified repairs

| Finding | Concrete failure | Final source verification |
| --- | --- | --- |
| P2: A live editor could overwrite or tombstone a row replaced by remote sync | A scene opened saved row A; remote reconciliation replaced the stored row with B; the editor's next autosave/stash or successful submission/discard could overwrite/delete B because the scene claim still matched. | `ComposerDraftManager.saveEditingSnapshot` now compares the actual decoded row with `expectedSavedDraft` before applying changes at lines 140–170. `deleteClaimedDraft` applies the same guard before tombstoning at 201–221. `SceneComposerEditingSession` supplies its baseline from autosave, stash, discard and completion; divergence preserves a visible local recovery row, acquires its claim, releases the changed source, increments revision and persists the new envelope in `preserveEditorAfterSavedRowConflict`. The source row's body, remote ID and sync metadata remain untouched. |
| P2: Selecting a saved draft lost recent live typing | The model was replaced before its current body reached the session; `preserveReplacedEditor` could therefore archive only the initial or last 30-second snapshot. | `PostComposerViewModel.replacementForSavedDraft` captures the live editor before creating/restoring the replacement at Lite 343 / Full 383. The UIKit saved-draft selection uses this helper. Full carries its destination, Circle service and reply lock into the replacement. |
| P2: A resumed editor left the dismissed model authorized | A new model resumed the same saved-row claim; an old photo callback or submission could still save/clear through that claim after the resumed model had new unsaved typing. | Each model now has a unique presentation ID. `SceneComposerEditingSession.claimEditor`, `ownsEditor` and `releaseEditor` provide a runtime presentation lease at 167–189. `ownsEditingDraft` checks that lease, and save/capture, discard, completion, transfer and minimize honor it. The saved-row claim remains stable for continuity while the old model loses authority. Lease state clears on replacement/completion/invalidation and is never restored from disk. |
| P2: Successful video-thread publication left the already-posted draft active | Thread embed preparation temporarily assigned and then cleared `self.videoItem`; the final unchanged-content comparison saw that internal mutation and rejected cleanup after a successful post. | Both thread embed branches use `withVideoForThreadEmbed`, which restores the previous video with `defer` at Lite `PostComposerCore.swift:593–597` / Full `:601–605`. The source now restores state on success and throw before completion checks. |

The shared `SceneComposerEditingSession`, `ComposerDraftManager` and session test suite are byte-identical in the two inspected variants. The caller fixes and equivalent regression cases exist in both.

## Storage and recovery assessment

The current boundary retains existing `DraftPost` rows and the encoded `PostComposerDraft` content format. Account-owned storage receives an explicit scene/account/token snapshot and optional saved-row ID; it no longer infers a row from one account-wide mutable editor slot. Static saved-row claims span replacement manager instances, and another scene cannot silently steal or delete a claimed row.

Stash and submission completion require the captured claim, revision, saved-row ID and body to remain current. Debounced writes check cancellation and the snapshot after sleeping. The additional runtime presentation lease prevents a previous model from reusing a valid continuity claim after another presentation resumes it. Because writes and baseline checks execute synchronously on the main actor, the final ownership check cannot suspend before the storage mutation.

The final live-model provider seam was also inspected in both variants. Registration requires the exact draft claim and runtime presentation ID; the provider weakly captures its view model. `flushLiveDraftProvider()` rechecks the claim and presentation before and after the callback and synchronously persists before invalidation, replacement or transfer. Teardown intentionally uses local ownership independently of task cancellation. The callback checks only its fixed claim, and local storage derives its account from the retained source AppState, so changing the global authenticated account cannot suppress source-account recovery. Remote-sync eligibility remains separately guarded. A resumed model takes its lease before reading the flushed body; stale unregister and isolated deinit calls cannot remove the replacement's provider. Identical content reuses serialized media references so these flushes do not manufacture a new revision, and submission teardown preserves the preflight body rather than temporary upload state.

Scoped minimized envelopes preserve the account, scene, optional row ID and baseline outside the content body. Recovery remints runtime tokens; a changed/missing/tombstoned source row restores as detached content. Invalidation/replacement preserves unsaved bodies in a visible library recovery row. Legacy `composerMinimizedDraft` bytes are retained unclaimed until an explicit recovery action first creates an account-owned durable row. Editor teardown does not unlink media files, protecting references still owned by a source row or another recovery/session.

The account-transfer payload carries only a new reopen ID, `sourceSceneID`, destination `accountDID` and content snapshot. It does not carry the source saved-row identity. The target must begin a new editing session with `savedDraftID == nil`; target Save creates its own row. The reviewed tests explicitly preserve source account/remote metadata and referenced image files across target save/discard.

## Account envelope and verified lifecycle repairs

`PendingComposerReopen` and `ComposerAccountSwitchQueue` expose the intended immutable, scene/account-scoped envelope. Queue admission is exclusive; same-account and busy outcomes do not replace an accepted attempt. A newer accepted switch invalidates unclaimed older handoffs. Pending lookup and atomic claim require the requested destination to be authenticated; claim also compares the exact ID and origin scene and removes that item synchronously. The picker now delivers an explicit verified switch outcome instead of treating every disappearance as success.

Destination status validation now precedes target AppState construction, and source retirement is awaited before constructing or refreshing the destination. The final Lite manager hash is `89a906458d8f77511f323cfa9bc3004554a4c6d85114674b9e0b3a92fc107bad`; Full is `b48cf10cc085eaf3f7227625e140eada8f6e17364638e64f71029f5c4753b336`. The following findings were sent to their owners and are closed by final source inspection:

| Severity | Finding | Verified repair |
| --- | --- | --- |
| P2 | Lite used synchronous cleanup before changing the shared client's credentials. | Lite now awaits `suspendForAccountSwitch()` before authentication changes, then revalidates the attempt and cancellation. The integration hook closes work admission, suspends pollers and drains tracked work. |
| P2 | Full could force restart solely because the picker was cancelled after its serialized switch committed successfully. | The wrapper forwards cancellation to the queue. `beginCommit` establishes the boundary before source retirement: cancellation prevents admission before it; afterward retirement settles independently and a verified successful target remains successful. Full advances account coordination only after awaited retirement and before target construction. |
| P2 | Rollback could publish an arbitrary remaining authenticated DID, including a restricted target; the first repair also missed restricted source lifecycles. | Recovery now handles any previous lifecycle with an AppState, requires its exact DID and retained client identity, restores that original lifecycle and returns or fails closed. Only an originally authenticated source resumes normal services. Deactivated source A therefore cannot make restricted destination B authenticated through fallback. Reactivation subsequently verifies explicit active status and the current source/client, awaits retained-service resumption, and only then publishes authenticated lifecycle, while holding the transition/operation barrier. |
| P2 | Logout during `.launching` lost the source DID and left a suspended source cached for later reuse. | Both managers retain the admitted source before publishing launching. Logout captures that source before revoking the attempt, waits for admitted work to settle, awaits source retirement and removes it from the cache before clearing authentication. |
| P2, integration compatibility | Calling `updateClient` before rollback resumption discarded Full's retained MLS manager. | The manager no longer calls `updateClient` in recovery. It requires the same retained client instance and calls `resumeAfterInterruptedAccountSwitch(using: client)`. Integration's inspected Lite hook at `AppState.swift:487` and Full hook at `:749` capture the original client before awaits, reject replacement instances, verify source DID and identity across service resumption, preserve the Full MLS graph and resuspend on partial failure. |

No lifecycle finding above remains open in the assessed source. The integration-owned hooks and Full `deferMLSStorageChanges` signature must still be composed with this lane into the complete applications and typechecked together. That is an integration/build gate, not an unresolved defect in the inspected call contract.

## Full preservation assessment

Focused comparison against the frozen social Full source found no subtraction of the reviewed Full-only behavior. The composer retains `CircleDestination`, reply destination locking, destination selection gates, injected Circle service, the active submission destination snapshot, public-only thread restrictions, Circle publication/notification, feature-enabled submit checks, audience controls and DEBUG Circle transport. Full's completion comparison includes destination.

Full native sharing retains both ordinary-chat and MLS (encrypted chat) activities, the rich shared-post payload, author/stat/image/gallery embed mapping and the existing `manager.sendMessage(convoId:plaintext:embed:)` API. The captured scene passes through the native activity into the recipient picker, with validity checks after asynchronous manager acquisition and send. The integration-owned Full `SceneNavigationContext.navigateToMLSConversation` helper was inspected separately: it navigates through that context's own manager and rechecks invalidation/origin after tab-selection callbacks. Standard conversation handoff preserves existing typed draft/reply state and exact scene/account ownership.

These are source-preservation findings, not encrypted-message delivery or Circle publication qualification.

## Required integration hook contracts

The following are deliberate integration-owned dependencies, not unexplained omissions or new feature findings:

1. Provide a stable `SceneNavigationContext` above the lifecycle/account-dependent ContentView replacement, with the appropriate account-bound `composerEditingSession` and scene-local `postComposerRequest`. A constructor inside the transient account ContentView cannot establish persistent origin identity.
2. Convert ContentView/ContentViewModifiers/CatbirdApp and incoming shared-draft consumers from removed manager-wide `currentDraft`, `loadSavedDraft`, `clearDraft` and `storeDraft` APIs. The scene lane's current shell still references those old APIs by agreement; the scene workspace is not an independently buildable complete app until this integration occurs.
3. Consume `pendingComposerReopenRevision`, call `pendingComposerReopen(sourceSceneID:accountDID:)`, then atomically `claimComposerReopen(id:sourceSceneID:accountDID:)` only in the originating ready scene. Present the returned immutable body; do not restore the old delayed global pending-draft observer. Begin the destination editor without a source saved-row ID.
4. Invoke session invalidation while its registered live view model is still retained; the new session API synchronously flushes that exact provider before invalidating ownership. Then replace the session with a new instance for the same scene/account. Do this for every affected window, independently of `onDisappear`, including when global authentication already names the destination. The provider's local recovery path does not depend on active authentication or task cancellation.
5. The presentation lease is a caller contract as well as a session API: a newly resumed model claims its unique presentation ID, and delayed model operations check `ownsEditingDraft`. Integration must not bypass it with an old model's direct session mutations. Minimized accessory/session-owner actions may use the continuity claim deliberately.
6. Preserve the scene-aware navigation helper's origin validation and the final async-throwing account lifecycle hook semantics when reconciling Full and Lite shell code.

## Tests inspected and remaining qualification

The session suite contains focused cases for independent scene rows, exclusive claims across manager replacement, stale claims/revisions, cancellation, runtime presentation leases, remote replacement before autosave/stash/discard/submission, visible recovery, missing/tombstoned rows, legacy recovery and transfer without source identity/media loss. The caller suite covers unflushed saved selection, an old media callback after resume, an unchanged old submitted body versus new unsaved resumed typing, and video preparation success/error. The unchanged-old-body case isolates lease ownership rather than merely failing a content-equality check. The added provider cases exercise autosave-free invalidation/replacement/transfer, stale registration/unregister, weak-owner lifetime, cancelled teardown, two windows with unsaved bodies, resume ordering, exact deinit ownership, stable image snapshots and submission scratch state. The cancelled-source caller fixture creates a separate target account model but does not mutate real global authentication; post-auth-change behavior is established here by the source's absence of a global-auth guard, not by an executed authentication test.

None of these tests were executed by this reviewer. Integration still needs to compile both complete apps with its final shell types/hooks, run the focused tests under the real targets, and exercise two-window restore/edit/discard, pending media after minimize/resume, video-thread successful cleanup, and account-switch cancel/failure/success on the running app. Preserve source/destination rows and inspect which scene reopens. No phone behavior, production action or publish/send operation was exercised here.

The account-switch suite's queue/barrier cases include cancellation before and after commit admission. Its final logout/restricted-rollback/reactivation checks inspect source ordering; they are not runtime authentication or service-resumption tests. Running-app qualification must additionally cover deactivated-source rollback and later reactivation, logout while authentication is suspended, and restoring a client with a different object identity.

## Source identity at final storage/composer review

SHA-256 values:

| File | Lite | Full |
| --- | --- | --- |
| `SceneComposerEditingSession.swift` | `8ae38cea7ab23f10fe352dfebe4eff38aba52b690dee46381f5ab4168e08cea9` | Identical |
| `ComposerDraftManager.swift` | `59fdd373222b7ca02517d4341c9b963b9a442feabdb201c660e5d56498be2725` | Identical |
| `PostComposerViewModel.swift` | `31ef0dde783cc087b25c68bd0b80c51350217c3b0fadfea4f9bcc0d9ae2a5fcf` | `815fe90e44b1c2ffb0495854c9207018f7d1eb05fdefaf3dd6675d0f6f572a71` |
| `PostComposerCore.swift` | `a8f71121ab3de9decf6f509d9543fdc72d54b314b110276b7fde3ac87a81601f` | `7c7263d3eaeebff878fb7d42235a0671eb520d968b480b76e3c3fe40d49b09d9` |
| `SceneComposerEditingSessionTests.swift` | `8ec96dc38ba93eeb10777f4966ce48b041453702218c7ff66ef3c8ebbc22855b` | Identical |
| `PostComposerSceneEditingTests.swift` | `33fa8569a32df936e0115d988394facf5ea5576563daf8212e9ebb4e9ee7d2cc` | `224d3d5b13f42550d337d2b6c671e3aa64c0a288de048c7637bf9021c54ff29c` |
| `PendingComposerReopen.swift` | `a56b346eb363b62633599df57d2a6eec54cfe87d9553b694bbeca846e82dade1` | Identical |
| `AppStateManager.swift` | `89a906458d8f77511f323cfa9bc3004554a4c6d85114674b9e0b3a92fc107bad` | `b48cf10cc085eaf3f7227625e140eada8f6e17364638e64f71029f5c4753b336` |
| `ComposerAccountSwitchQueueTests.swift` | `c9fe50687118b5a9c80557defd15dc61718295b9e9ae03cf66d274b000e9843f` | Identical |
