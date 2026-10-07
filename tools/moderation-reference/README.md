# Moderation reference (golden)

`golden.json` holds expected moderation results computed by running the real `@bsky/sdk` moderation code
(`moderatePost`, `moderateProfile`, `interpretLabelValueDefinitions`, and the `getPreferences` parse), so the Swift
port in `Catbird/Core/Moderation` is tested against shipped behavior. `CatbirdTests/Moderation/ModerationReferenceGolden.swift`
embeds the same JSON as `ModerationReferenceGolden.json` (raw-string chunks joined at runtime).

**Pinned reference:** `@bsky/sdk` 1.0.1 as installed in the official social-app checkout, commit
`5b88335bb118f4f65dcb564e10109d6c6a78cb67` (`meta.sdkSourceHashes` records the behavior-defining sdk files).
The generator refuses any other version or commit unless `--allow-unpinned` is passed.

**Rerun** (deterministic; `--check` fails if the files on disk differ from a fresh run):
`node Catbird/tools/moderation-reference/generate-golden.mjs --sdk <social-app>/node_modules/@bsky/sdk --social-app <social-app>`

## Layout
- `prefs[]`: `{id, raw[{label, visibility, labelerDid?}], adultContentEnabled|null, labelers[], normalized, catbird?}`. `normalized` is the real
  `getPreferences()` output (defaults seeded, `nsfw/gore/suggestive` remapped in array order with the legacy name also set, `show` becomes
  `ignore`, unknown visibilities and Catbird's private `graphic` key passed through, labeler-scoped prefs attached only to subscribed or app labelers).
  Visibilities stay strings exactly as the sdk holds them, the empty string included.
- `prefSets{}` and `definitions{}`: shared inputs. `scenarios[].input.prefs` is a `prefSets` key; `input.labelDefs` is a list of `definitions`
  keys, each `{definedBy, raw, interpreted}` (`interpreted` is the real `interpretLabelValueDefinitions` output).
- `scenarios[]`: `{id, input, expected, catbird?}`. `input` = `{kind: post|profile, shape, userDid (null = logged out), prefs, labelDefs?, subject}`;
  `subject` is what the sdk received and decodes straight into the typed models: fields the lexicons require but moderation never reads
  (`cid`, `indexedAt`, an empty post record) carry placeholder values. `meta.now` is the clock for `exp`.
- `expected.contexts` covers all eight contexts. Only non-default values are stored: an absent context, boolean or list means
  false or `[]` and must still be asserted. Entries without `type` are label causes `{val, src, target, priority}`;
  entries with a `type` (`blocking`, `blocked-by`, `muted`, `mute-word`, `hidden`) are restriction causes the Catbird engine does not model.
  `expected.decision.causes` is the full cause list in sdk order (`isMe` only when true).
- `meta.builtinLabels` is the sdk's `LABELS` table (the deprecated `gore` alias is a separate entry with its own identifier);
  `meta.defaultLabelSettings` is `DEFAULT_LABEL_SETTINGS`.
- Scenario ids read `family/value/source/adult/pref/viewer`. The full cross-product is sampled; `meta.counts` has per-family totals.

## How the Swift suites consume it
- `ModerationReferenceConformanceTests` runs every scenario through `ModerationSubjects.decidePost` / `decideProfileSubject` and asserts
  all eight contexts (filter, blur, alert, inform, noOverride and the ordered cause lists) plus `decision.causes` against `expected`, or
  `catbird.expected` when present. Scenarios whose sdk result also holds restriction causes (`restriction/*`, `blockedquote/*`) are compared
  on their label causes only; the flags are derived from the label entries and, for every other scenario, checked against the stored flags.
  It also compares every interpreted definition and the builtin table with the sdk's.
- `ModerationPrefsGoldenTests` runs every `prefs[]` case through `ModerationPrefs.init(adultContentEnabled:contentLabelPrefs:labelerDIDs:)`.
  A stored visibility is read the way the engine acts on it: `ignore`/`warn`/`hide`/`show` as themselves, any other non-empty string as an
  explicit `warn`-like preference, and the empty string as no preference.

## Intentional Catbird deviations (only scenarios and preference cases with a `catbird` field differ; all others must equal the sdk)
1. Negated (`neg:true`) and expired (`exp` at or before `meta.now`) labels are ignored; the sdk reads neither field.
2. A labeler definition that redefines `porn`, `sexual`, `nudity`, `graphic-media`, `gore`, or any `!`-prefixed value is ignored
   (the sdk honors the five plain redefinitions and already ignores `!` ones, so those `catbird.expected` equal the sdk).
3. An exact duplicate label (same `src`, `uri`, `val`) in one list counts once; a different uri, source or value is not a duplicate.
4. Catbird's former private preference key `graphic` is read as `graphic-media` when the stored preferences hold no global `graphic-media`
   or `gore` entry (any visibility value counts as an entry; labeler-scoped entries do not). Otherwise `graphic` stays an inert key, as in the sdk.
   Preference cases only; a case carries a `catbird` field only when this changes its result.

`catbird.expected` is the real sdk run on the transformed input (label or definition removed, `graphic` renamed), never hand-written.

## Differences the suites tolerate that are not scenario deviations
- `interpretLabelValueDefinition`: the engine returns `nil` for a definition whose identifier is reserved (a builtin or a `!` value) or does not
  match `^[a-z-]+$`. The sdk interprets both; the second can never be looked up, and the first is deviation 2.
- `blurs` / `severity` strings the sdk does not recognize (`weird` in the golden; both are open strings in the lexicon): the sdk passes
  them through unchanged in `interpreted`, while the engine stores its closed `none` value in `ModerationLabelDefinition.blurs` / `.severity`.
  The suites compare those two raw fields only when the golden value is `content`, `media`, `inform`, `alert` or `none`, and require `none` for
  anything else; the behaviors are always compared in full (an unknown `blurs` has none, an unknown `severity` never alerts or informs).
- Block, mute, muted-word and hidden-post causes are not produced (blocks, mutes, muted words and hidden posts keep their current code paths).

## What the sdk does that is easy to get wrong
- `gore` is a builtin label value of its own (identifier `gore`, preference key `gore`, behaves like `graphic-media`); it is not remapped to
  `graphic-media` when a label is evaluated. Only a stored `gore` preference is also copied to `graphic-media` on read.
- A stored visibility is read by truthiness: any non-empty string other than `ignore` and `hide` (`block`, `HIDE`, `Show`) overrides the default
  and acts like `warn`; the empty string falls through to the next source. Matching is case-sensitive.
