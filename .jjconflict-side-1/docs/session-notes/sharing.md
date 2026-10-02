# Post sharing implementation lane

This work adds Catbird Lite's requested post share menu and makes the Bluesky chat handoff explicit, cancellable and account scoped. The implementation reuses the existing shared-post message attachment and leaves sending to the conversation's Send button. Source changes and focused regression tests are ready for the lane owner's coordinated build and simulator fixture pass; runtime qualification is not yet claimed. Integration owns the final commit, project membership, full-app counterpart and phone verification.

Governing work: [parallel execution plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md), [LITE-011 feedback](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/qa/catbird-lite-live-feedback.md#lite-011--add-a-custom-post-share-menu-with-chat-destinations), and [resizability review](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/qa/iphone-resizability-reference-review.md). Starting Lite candidate is `f0ca2f5334ac87fd53ac30f50861f296576c8051` with frozen sibling Petrel `329b5fbe412286ff4c094246b6f30c2989e58f94` and overlay `ff98deedc748777537f912fa4dcd208f9bbc840e` selected by integration.

## Result and owned files

- `ActionButtonsView.swift`: reusable `PostShareMenu(post:appState:isBig:onChooseChat:onCopyLink:onChooseMore:)` with Send to Bluesky chat, Copy Link and More. Native and recipient sheets attach to this view. Optional action closures let the DEBUG fixture avoid clipboard/transport side effects.
- `ActionButtonsViewModel.swift`: one URL builder for handle/DID fallback. The unused global-window share method is removed after both Lite and exact full-reference caller searches showed only the replaced ActionButtonsView call. Repost false outcomes are propagated as errors.
- `ShareToChatActivity.swift`: native activity item uses that same URL; contextual native sheet retains Bluesky activity. `ShareRecipientSelectionModel` implements query generations, cancellation, selected-account validation, typed lookup errors and request injection. Live requests use frozen Petrel's exact-auth request scopes, availability before get-or-create, and no automatic send. `ModernChatSelectionView` accepts optional model/conversations/selection callback for local fixtures.
- `PendingChatShare.swift`: unique handoff identity, explicit account DID, account/conversation-keyed observable store and single-use consumption. Its apply helper changes only the post attachment.
- `ConversationView.swift`: observes pending-store revision, including the already-selected-conversation case; checks active account and draft owner; asks before replacing a different post while retaining text and reply.
- `PendingChatShareTests.swift`: existing preview tests plus account isolation, one-time and stale-confirmation consumption, text preservation, handle/DID link fallback, search ordering/clear/failure/retry, selection cancellation/account switch/duplicate tap, and message-policy direction/blocking.

A bounded child owns the separately requested repost outcome correction in `PostViewModel.swift` and `PostViewModelRepostOutcomeTests.swift`; its own report records status. Shared like/repost signatures stay unchanged for the video lane.

## Provisional choices for integration's decision log

Chose native SwiftUI Menu with explicit More; omit the optional native-share long press. A native Menu already owns long-press behavior, and introducing another competing recognizer risks opening two presentations. Reversible until merge by adding a separately tested exclusive gesture policy.

Chose an account/conversation-keyed PendingChatShareStore in the existing model file, leaving global navigation types untouched. Existing per-account AppState/navigation ownership already reduces account mixing; the new scope is hardening and a testable guarantee, not evidence of a previously reproduced disclosure. Integration may remove the obsolete unused AppNavigationManager.pendingChatShare field.

Chose availability checking plus exact-auth-scoped direct endpoint calls for the picker. ChatManager.startConversationWith currently publishes async results without sufficient cancellation/account checks; the picker now validates before synchronously caching returned conversation metadata and staging. This does not claim the general ChatManager path is repaired.

## Full counterpart constraints

Full reference `d0957b4cb885466807f940ab8e090fce75674567` has one share(post:) caller in ActionButtonsView. Keep its canPublicShare capability condition, its canRepost gate, MLS activity availability in native More, and ShareablePost's MLS payload handling. Full PendingChatShare preview uses MLSEmbedData and rich MLSPostEmbed fields; retain that implementation and only apply the account/store/apply seams. Do not overwrite these files with the Lite versions wholesale.

## Verification boundary

Source parsing passed for all sharing files and tests. No account operations, messages, appeals, reactions, production mutations, phone installation or heavy builds were performed by this worker. The lane owner is running the authorized combined build and fixture UI verification and will append receipts. Required runtime checks include menu tap/cancel, injected Copy, native More cancel on phone/tablet, fixture recipient eligibility/errors, staged preview, and existing-conversation handoff. Authenticated device behavior remains a separate integration gate.
