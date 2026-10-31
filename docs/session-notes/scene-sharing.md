# Scene-owned post sharing and draft delivery

This change keeps post actions, recipient selection, and staged chat attachments in the Catbird window where the user started them. The previous share handoff distinguished accounts and conversations but could be claimed by another window displaying the same conversation. Lite and Full now capture the originating scene context and require the matching scene, account, conversation, and handoff token before applying an attachment. Source parsing and preservation checks have passed; integrated build, test execution, and two-window runtime verification remain with the integration owner.

The governing plan is [live-feedback parallel execution](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md), LITE-017 (scene and presentation ownership). Core context, routing policy, account lifecycle, and composer ownership decisions remain under the integration owner's [decision log](/Users/joshlacalamito/Documents/Codex/2026-10-02/task/main-consolidation/WorkspaceDocs/docs/DECISIONS.md). This lane made no independent wire/schema or dependency decision.

## Source scope

- `ActionButtonsView` reads its injected `SceneNavigationContext`. Reply and quote actions use its composer request, so they no longer clear an account-wide draft or present through global navigation. Full retains its reply/repost/quote/like/public-share capability checks and forwards the Circle reply destination through the Full-only `destination:` composer parameter.
- `PostShareMenu` stores the exact context with each sheet destination. The native share activity and Bluesky recipient picker receive that captured context explicitly. A context invalidated by closing or changing the account in the window cannot publish a later lookup result, stage a post, or route another window.
- `ShareRecipientSelectionModel` carries the captured account and scene plus a context-validity predicate. Exact authentication-continuity guards remain around server lookup/creation. Search and selection generation checks still suppress superseded/cancelled completions. The final navigation path checks context validity again after invoking the tab-selection callback.
- `PendingChatShareStore` keys entries by scene, account, and conversation. Claims also require the expected immutable token. Scene/account invalidation discards only matching attachments, preserving other windows and accounts. `ConversationView` binds its own draft to its initializing scene/account and preserves replacement confirmation, typed text, and reply context.
- Lite's Messages-schema draft handoff stages immutable tokens and prepares the exact binding in the route coordinator's pre-delivery callback. It publishes only in a deferred MainActor turn after revalidating the binding and invalidation state; unpublished entries cannot be peeked or consumed. The intended empty composer then uses peek plus exact-token consume. Invalidation revokes delivery while retaining text, and successfully consumed text remains in a nonclaimable account-scoped recovery archive. Retention is in memory; no recovery UI is introduced.
- Full preserves its secure-share UI activity, MLS recipient picker, rich post embed factory, and rich Bluesky composer. The MLS picker captures a scene, checks validity across loading/sending awaits, and routes successful sends through that scene's MLS navigation helper. Full Messages-schema intent drafts continue to target MLS consumers; standard Bluesky ConversationView consumes only shared-post attachments.

The focused Full durable draft implementation is source-complete and requires the integration owner's MLS consumer wiring. It preserves legacy protected-storage APIs while storing new `SceneChatDraft` envelopes in a separate protected table. A scoped consumer peeks durably, revalidates its scene, synchronously consumes the exact token and inserts the text, then acknowledges durable consumption. Legacy consumers cannot take new scoped rows.

## Tests and verification boundary

Updated tests cover two windows displaying the same account and conversation, wrong-scene/token claims, scene invalidation, account replacement and return, and in-flight recipient lookup invalidation while another scene remains valid. Existing replacement-token, preserved-text, request-order, cancellation, eligibility, and duplicate-tap coverage is retained. Offline fixtures and layout tests inject a concrete scene context; the fixture author is eligible for the intended recipient-search path.

`swiftc -frontend -parse` passes for the seven sharing-owned Swift files in both variants. This is syntax verification, not a typecheck or test run. Source comparison confirms Full's rich pending-post preview factory, MLS send embed factory, MLS conversation-row rendering, and existing capability gates are preserved. Global navigation, global composer clearing, first-window selection, and dynamic current-scene fallback are absent from the sharing-owned production files.

No Xcode build, test execution, app launch, device action, generated source, project configuration, VCS mutation, or frozen original `social/` source edit occurred in this scene lane. The integration owner must combine the shared context, composer session, routing callback, and lifecycle contracts before compiling.

## Integration and runtime gates

1. Combine both focused patches with `SceneNavigationContext`, its invalidation hooks, `SceneRouteCoordinator.submit(...beforeDelivery:)`, the shared composer editing-session registry, and Full's destination-carrying composer request.
2. Wire Full's iOS/macOS MLS conversation and direct-compose consumers to the scoped durable peek/claim/ack APIs. Preserve legacy direct-compose payload compatibility and explicit recovery access.
3. Build Lite and Full and execute `PendingChatShareOwnershipTests`, `ShareRecipientSelectionTests`, the Messages-schema handoff tests, and the affected layout tests. Record failures separately from frozen pre-scene test results.
4. In the running app, open the same account and conversation in two windows. Stage a post from each window, then confirm each window sees only its own post and that replacing an attachment preserves text/reply context. Resize both windows and repeat.
5. Start a delayed recipient lookup, close or change the originating window's account, then finish the lookup. Confirm no route or attachment appears in either replacement window. Repeat with a queued Messages-schema draft and verify text remains recoverable.
6. In Full, verify Circle reply stays in its Circle destination and the secure-share activity retains rich preview, existing send behavior, and scene-local completion routing. Capture screenshots and relevant runtime logs without making an unsolicited real send.

## Independent Full source review

The Full sharing reviewer found no new P1/P2 issues in the scene delta. It verified the native MLS/Bluesky activities and payloads, unchanged rich embed mapping and send API, explicit menu-to-activity-to-picker scene propagation, guarded async completions, and the integration helper's repeated validity check after its tab-selection callback. A final source comparison also confirms the Full rich composer and the rest of its conversation rendering are byte-identical to the pre-scene source. This review did not compile or execute the app/tests.

## Draft-delivery review follow-up

The Lite source reviewer found and rechecked a P2 ordering race: synchronous draft publication could let an existing composer consume text before a tab-selection callback invalidated the intended scene. The completed repair keeps binding unpublished and unclaimable until a deferred MainActor turn verifies the exact binding and invalidation state. Consumed text remains in a nonclaimable recovery archive. Full durable acknowledgment marks the token consumed while retaining its payload; durable eligibility separately requires consumed=0. Deterministic regressions cover bind → invalidate → publication drain without a claim, and accepted publication with exactly-once consumption and recovery retention. The reviewer confirmed the P2 is resolved in both variants and reported no further actionable finding in this bounded fix.


## Final source handoff

All ten changed Swift files in each variant are stable for integration. The seven sharing-owned files and the three Messages-schema source/test files parse in both variants. Lite now has ten handoff tests; Full adds nine scoped/durable tests while retaining every original MLS fixture/test. Full source comparison confirms its legacy `PendingChatDraft` DTO and legacy store/consume/durable method block are unchanged, as are Send and all subsequent intents. These are source and parser receipts; the tests have not run in this lane.

The provisional Full storage choice adds `app_chat_scene_draft_handoff` inside the existing protected MLS database, keyed by immutable token/account, while preserving the legacy table and payload. The consumed flag prevents replay and the retained payload permits explicit recovery inspection. This is reversible before integration; no runtime schema change was executed here. The integration owner owns the final decision-log entry and MLS consumer reconciliation.
