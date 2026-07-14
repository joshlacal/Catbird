# App Intents

Siri / Shortcuts / Spotlight surface for Catbird. Layers:

## Generated/ — DO NOT EDIT

Everything under `Generated/` is emitted by the Petrel lexicon generator from
the curated manifest at `Catbird/manifests/app-intents.json`. To add, remove,
or change an intent/entity: edit the manifest (or the generator/templates in
`Petrel/generator/`), then regenerate:

```bash
cd Petrel && python3 run.py --manifest ../Catbird/manifests/app-intents.json swift
```

Checkpoint (`jj new`) in BOTH the Petrel and Catbird repos before running.
The generator hard-fails on lexicon shapes that don't map to App Intents
(unions, `unknown`, composite refs) — that's curation feedback, not a bug.
See `docs/superpowers/specs/2026-07-07-app-intents-lexicon-codegen-research.md`
in the workspace root for the design.

The `Generated/` set includes `recordWrite` intents (Like/Unlike, Repost/
Unrepost, Follow/Unfollow, Block/Unblock): hydrate the subject entity's fresh
view (cid + viewer state), short-circuit on already-done, then
createRecord/deleteRecord. All generated intents speak an `IntentDialog`.

## Support/ — hand-written runtime

- `IntentClientProvider` — per-DID cached standalone `ATProtoClient`
  (gateway/keychain-only bootstrap mirroring the NotificationServiceExtension;
  never touches `AppState`).
- `IntentError` / `unwrapIntentResponse` — maps the generated client's
  non-throwing `(responseCode, data?)` tuples into thrown errors.
- `IntentRecordWriteSupport` — viewer-URI → rkey parsing for the generated
  recordWrite delete intents.
- `AccountEntity` / `IntentAccountResolver` — account parameter + active-DID
  default, backed by the `group.blue.catbird.shared` app group.
- `SpotlightEntityDonator` — donates Post/Profile entities (IndexedEntity) to
  the Spotlight semantic index; called from feed + profile load paths.
- `CatbirdShortcuts` — the curated `AppShortcutsProvider` phrase set. Note:
  Xcode's `appintentsmetadataprocessor` rejects an empty `appShortcuts` body,
  so the provider must always contain at least one shortcut.

## Top level — hand-written intents

- `CreatePostIntent` — actually publishes (PostParser facets, image blob
  uploads, reply/quote hydration, `requestConfirmation()` before the write).
- `ComposePostIntent` ("Draft Post") — stages a draft through the app-group
  `incoming_shared_draft` slot drained by `IncomingSharedDraftHandler`.

## DirectMessages/ — Bluesky DMs (chat.bsky.convo, hand-written)

`BskyConversationEntity` + Send/GetConversations/UnreadCount/MarkRead intents
against the standalone client (chat service proxy is automatic). Deliberately
NOT in the iOS 27 Messages App Schema — that domain is MLS-only (below), and
ConvoView's lastMessage union rules out entity codegen.

## MessagesSchema/ — iOS 27 Messages App Schema domain (hand-written)

The five `@AppIntent(schema: .messages.*)` intents plus
conversation/message/messagePerson schema entities for MLS chat.
The messages domain is all-or-nothing: adopting any of the five requires all
five (Xcode build-validates). Wire protocol for edit/unsend is specced in
`docs/MLS_CLIENT_PROTOCOL.md` §5.7–5.9.

Tests: `CatbirdTests/AppIntents/`.

