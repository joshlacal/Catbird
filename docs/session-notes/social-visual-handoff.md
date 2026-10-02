# Social visual follow-up

This change closes two rendering gaps reproduced while validating profile and moderation actions. Profile statistics could split English captions in the middle of a word at a 320-point width with accessibility text. A failed appeal preserved the entered reason, but the keyboard could hide its error and retry control. Both Lite and Full now use adaptive statistics layout and reveal the appeal failure. Targeted simulator recapture remains pending on the combined build.

Governing plan: [live feedback execution plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md). Decision: [adaptive statistics and visible appeal retry](../DECISIONS.md).

## Changes

- ProfileHeader uses a natural-width horizontal group when it fits, otherwise vertically arranged statistics. Each statistic has a further vertical count/caption fallback for a narrow width or long translation. Navigation, localized caption keys, typography, number formatting and combined accessibility elements are retained.
- The appeal form clears reason-field focus when submitting. A current-viewer/current-label failure scrolls the persistent submission section into view and presents an enabled Retry Appeal button; the typed reason stays intact. Existing attempt cancellation and account guards remain.
- Existing component captures now require the full Following, Followers and Posts captions except in the deliberately short scrolled sample. The existing failed-appeal journey checks the keyboard was present before submission, absent after failure, reason unchanged, error and enabled retry visible and within the window, then captures the same screenshot.

## Verification

Both variants: four touched Swift files parse; scoped SwiftLint exits 0 with zero errors (26 pre-existing/style warnings each). Independent review is source-only. Runtime verification will execute only `CatbirdTests/SocialComponentLayoutTests/testProfileGermActionResizesAtLargeText` and `CatbirdUITests/SocialActionsUITests/testLabelMetadataAndFailedAppealPreserveReason`, capture the same fixture views and inspect the rendered output. No actual appeal, account write or production action is authorized by these fixture checks.

Prior fixture results are recorded in the [original runtime report](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social/evidence/runtime-validation-report.md); they do not qualify this follow-up. The source and runtime receipts for this follow-up live in `/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social-visual/evidence/`.
