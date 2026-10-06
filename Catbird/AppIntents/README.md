# App Intents

Siri / Shortcuts / Spotlight surface for Catbird. Layers:

## Generated/ — DO NOT EDIT

Everything under `Generated/` is emitted by the Petrel lexicon generator from
the curated manifest at `Catbird/manifests/app-intents.json`. Never hand-edit
the output: change the manifest (or `generator/app_intents_generator.py` and
`generator/templates/app_*.jinja` in Petrel), then regenerate. The generator
lives on the Petrel branch `codex/app-intents-main-20261002`; run it from a
checkout of that branch:

```bash
python3 <petrel-checkout>/run.py --manifest Catbird/manifests/app-intents.json --language swift
```

Lexicons resolve to `../../Petrel/generator/lexicons` relative to the
manifest. When those lexicons gain optional parameters, add them to
`excludeParameters` (or give them a `title`) — otherwise the lexicon
description becomes the Shortcuts title. Generator tests:
`cd <petrel-checkout>/generator && python3 -m unittest tests.test_app_intents_generation`.

Curation keys beyond the lexicon shape:

- `typeDisplayName` (entity) — user-facing type name and the noun Siri speaks
  ("Feed", not "FeedGenerator").
- `customProperties[].exposed: false` + `default` — a plain stored field kept
  out of Shortcuts (e.g. the post record key).
- `parameters.<name>.prompt` — the question Siri asks for a missing value.
- `dialogOne` (scalar Int returns) — the singular sentence spoken when the
  result is 1; `dialog` covers every other count.

Dialogs are emitted as `IntentDialog("…")` (localizable
`LocalizedStringResource` keys), with singular and plural as whole sentences.

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
  `IntentError` is `CustomLocalizedStringResourceConvertible`: Siri and
  Shortcuts only speak a thrown error's message for that protocol, so every
  user-facing failure must go through it (a plain `LocalizedError` is shown
  as a generic failure).
- `IntentRecordWriteSupport` — viewer-URI → rkey parsing for the generated
  recordWrite delete intents.
- `AccountEntity` / `IntentAccountResolver` — account parameter + active-DID
  default, backed by the `group.blue.catbird.shared` app group.
- `SpotlightEntityDonator` — donates Post/Profile entities (IndexedEntity) to
  the Spotlight semantic index. Every rendered post seeds `PostEntityStore`
  (deadline-safe Siri resolution), but only engaged posts — authored, liked,
  reposted, bookmarked, or opened as a thread — are indexed in Spotlight.
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
against the standalone client (chat service proxy is automatic). ConvoView's
lastMessage union rules out entity codegen.

## MessagesSchema/ — iOS 27 Messages App Schema domain (hand-written)

The five `@AppIntent(schema: .messages.*)` intents plus
conversation/message/messagePerson schema entities for Bluesky DMs
(chat.bsky.convo via the standalone client).
The messages domain is all-or-nothing: adopting any of the five requires all
five (Xcode build-validates). chat.bsky has no edit/unsend, so those two intents
fail with an explanatory error; mark-unread is likewise unsupported.

Tests: `CatbirdTests/AppIntents/`.

