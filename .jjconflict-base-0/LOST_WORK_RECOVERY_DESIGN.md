# Lost Work Recovery Design

## Status

Approved recovery architecture. Implementation remains gated on review of this document and a separate execution plan.

## Problem

The current `main` line no longer contains a substantial set of product behavior that still exists on preserved feature lines. The loss was caused by branch movement and an incomplete integration sequence, not by destruction of the underlying commits.

The visible regressions include the feed-start presentation, unified-profile banner geometry, and the morphing compose FAB. History inspection also found less-visible behavior in drafts, composer presentation, search, feed correctness, chat, MLS ordering, settings, threaded replies, and App Intents.

A direct merge is unsafe. Current `main` contains newer OAuth, security, reply-thread, repost-menu, and selective App Intents work. The preserved feature line also contains checkpoints, superseded implementations, and generated-code changes that must not overwrite newer sources of truth.

## Recovery Goal

Recover every still-valid product behavior from the preserved history onto current `main`, while retaining newer fixes and intentionally excluding:

- committed conflict markers and incomplete snapshots;
- checkpoint-only or exploratory changes;
- obsolete OAuth and security behavior;
- stale generated App Intents or API output;
- implementations superseded by a demonstrably newer equivalent on `main`.

The recovery is complete only when the restored behavior is observable in the running app. A clean merge or successful compile alone is not sufficient.

## Evidence and Source Lines

The recovery is based on these preserved Git commit identities:

- Current baseline: `bfa9395512daedb6255f97390df47a9333d11bee` (`main`)
- Clean broad feature head: `88818854beac35b0b5733bf94b76cee940a641fb` (`search-filtering-merged`)
- Focused compose-FAB head: `f7322e39b7ba880c853875c70f4b450f33668045` (`feature/compose-fab-quick-actions`)
- Unsafe conflicted snapshot: `1b01b528` (`feature/refactor-feed-and-post`), evidence only
- Broad-line merge base: `21fbbd526f43592fab7d5a86aedafdb0692a965d`

The unsafe snapshot must never be merged or transplanted. It may only be inspected to locate intent that is then corroborated against a clean commit.

## Chosen Strategy

Use selective behavioral reconstruction on top of current `main`.

Each recovery slice will be reconstructed from the clean preserved commits, reconciled with the current implementation, verified independently, and committed independently. This favors product behavior and current architecture over reproducing the exact historical diff.

The rejected alternatives are:

- Wholesale merge of `88818854`: the branches differ across 182 files and the merge would mix valid UI work with superseded infrastructure and generated output.
- Rebase of the full feature stack: the stack contains checkpoints and WIP, producing a long conflict chain whose historical shape is not itself valuable.

## Repository and VCS Isolation

Before implementation:

1. Preserve the clean source heads with explicit rescue bookmarks.
2. Create an isolated `jj` workspace from current `main` for `codex/recover-lost-catbird-work`.
3. Keep the `main` bookmark unmoved throughout reconstruction.
4. Record baseline build and test results before the first behavioral change.

Every slice gets its own described commit. If a slice fails verification or proves obsolete, only that slice is revised or abandoned. Unrelated working-copy changes must never be absorbed into recovery commits.

## Recovery Slices

### 1. Feed Start and Unified Profile Geometry

Restore the larger feed-start icons and the final profile-banner layout, including the concentric lower curve, full-bleed positioning, alignment, and extracted banner-header structure.

Primary historical chain:

- `d062c2a`: larger feed icons and initial banner geometry
- `8e2b09d`, `650f738`, `2f3f4cc`: successive banner corrections

The final behavior, rather than an intermediate geometry, is the target.

### 2. Drafts and Composer Presentation

Restore the drafts/AppView synchronization and composer redesign before wiring FAB entry points. This establishes a stable destination for New Post and Browse Drafts.

Primary historical commits:

- `412bb74`: drafts synchronization and redesign
- `4e833ba`: composer redesign, chips, and accessory behavior

### 3. Compose FAB and Media Quick Actions

Restore the single-orb morphing FAB and its actions:

- New Post
- Browse Drafts
- Take Photo
- Record Video

Primary historical chain:

- `17a4479`, `cc1952b`, `51036b1`, `670c265`, `ea75016`, `f7322e3`
- `08e7368`: single-orb behavior correction
- `dd7fde8`: circle and presentation polish

Camera and video flows must preserve any active draft and use supported platform APIs. Simulator-only verification is insufficient for capture behavior.

### 4. Search and Feed Discovery

Recover the still-valid search-filter behavior, saved-search loading, cursor reset, language precedence, and feed discovery integration.

Primary historical chain:

- `fea6386`, `dfb0b1e`, `19ae89a`, `29ab384`, `8881885`

The current backend/API capabilities must be checked before retaining any historical filter. Unsupported synthetic filters are not part of the recovery target.

### 5. Feed Correctness

Recover repost-cache and header-bleed corrections from `68043cb`, reconciling them with the newer repost-menu revert on `main`.

This slice must be behaviorally narrow: cache correctness and visual containment must not reintroduce menu behavior that was intentionally reverted.

### 6. Chat and MLS Ordering

Recover own-message edit/unsend behavior from `d5eefcd` and the sequence-zero timeline anchor from `d06e076`.

Because these affect message state and ordering, tests must cover both local presentation and persisted/server-derived state. MLS recovery invariants and epoch handling must remain unchanged unless the historical behavior explicitly requires an API reconciliation.

### 7. Settings Runtime Wiring

Recover valid settings behavior from `10f1c17`, comparing every setting against the current preferences and application state models. Presentation without a functioning runtime consumer is not considered recovered.

### 8. Threaded Replies

Evaluate `b86c5ca` against the newer sibling-reply implementation already on `main`. Port only behavior that is absent or demonstrably more complete.

This is a semantic reconciliation, not a cherry-pick. Current `main` wins when both implementations cover the same behavior unless runtime verification demonstrates a regression.

### 9. App Intents and Generated Artifacts

Reconcile App Intents last, after the navigation and composer destinations they invoke are stable.

Current `main` contains a selective App Intents recovery and newer authentication/security work. Historical App Intents code may be used as behavioral evidence, but generated metadata and API types must be regenerated from their canonical definitions. Generated files must never be blindly copied or hand-edited.

Physical-device validation is required for Siri, entity resolution, authentication, and any camera-related intent.

## Conflict Policy

For every conflict, classify both sides before editing:

1. **Current infrastructure vs historical presentation:** keep current infrastructure and adapt the historical presentation.
2. **Equivalent behavior on both lines:** keep the newer current implementation unless the preserved line has verified additional behavior.
3. **Generated output:** resolve at the source schema, manifest, or intent declaration, then regenerate from a clean checkpoint.
4. **Security or OAuth behavior:** retain current `main` by default; deviations require explicit evidence and focused review.
5. **Unknown intent:** stop the slice and trace its introducing commit and call sites rather than guessing.

No resolution may retain conflict markers, dead compatibility branches, or duplicated feature entry points.

## Verification Strategy

### Baseline

- Record the clean baseline revision and dirty status.
- Build the current app for the primary iPhone simulator.
- Run the existing relevant tests and record pre-existing failures.

### Per Slice

- Review the slice diff for unrelated changes.
- Build the Catbird scheme.
- Run focused unit or integration tests.
- Launch and navigate to the affected behavior.
- Capture screenshots for UI changes and logs for stateful behavior.
- Test compact and regular width when layout is affected.
- Test Reduce Motion and Reduce Transparency for morphing/glass UI where applicable.

### Final Matrix

- iPhone simulator: build, tests, primary navigation, feed, profile, search, drafts, composer, and FAB.
- iPad simulator: regular-width layout and profile/banner containment.
- macOS: build and shared-code regression coverage.
- Physical iPhone: photo/video capture, draft preservation, Siri, App Intents, and entity lookup.

The final report will distinguish verified behavior from any device-state blocker. A blocked physical-device check will remain an explicit open gate.

## Rollback and Auditability

- One behavioral slice per commit provides the rollback boundary.
- Generated output is preceded by a clean `jj` checkpoint in every affected repository.
- Source bookmarks remain available until final acceptance.
- The recovery branch is not moved onto `main` until the full verification matrix and final diff audit pass.
- A recovery ledger in the execution plan will map every candidate historical commit to one of: recovered, already present, superseded, or intentionally excluded.

## Acceptance Criteria

Recovery is accepted when:

- every known candidate behavior has a ledger disposition;
- all nine slices are either verified or explicitly excluded with evidence;
- the app builds on iOS and macOS targets;
- relevant automated tests pass or pre-existing failures are documented;
- UI changes are confirmed with runtime screenshots;
- camera, video, and App Intents have physical-device results;
- current OAuth and security behavior remains intact;
- generated sources match their canonical inputs;
- no conflict markers, duplicate entry points, or unrelated changes remain;
- `main` has not moved during reconstruction.
