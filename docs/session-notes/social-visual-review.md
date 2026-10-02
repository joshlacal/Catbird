# Independent review of the social visual follow-up

This follow-up addresses profile statistics splitting into narrow fragments and the keyboard obscuring a failed label appeal's error and retry action. The review covered only the paired Lite and Full view changes and their focused test changes. One P2 layout finding was reported and repaired; no remaining P1/P2 was found in the final inspected source. Both deltas are clear for source sealing, with builds, screenshots and UI-test execution still owned by integration. Earlier test receipts and binaries remain evidence for their original source, not these new changes.

Governing plan: [live feedback parallel execution](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md). No API, persistence or account-lifecycle contract changed, and this review introduced no new architecture decision.

## Scope and evidence boundary

- Lite workspace: `/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social-visual/Catbird`; coordinator-supplied base `181e64f2`.
- Full workspace: `/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/social-visual/Full/Catbird`; coordinator-supplied base `77c09874`.
- Inspected the final source and focused test changes. Profile layout received a separate independent source pass; appeal focus, scroll and submission-state preservation were reviewed directly.
- This reviewer ran no build, parser, test, simulator, network action or VCS command. Owner-reported parsing and earlier runtime receipts are not claimed as independent execution evidence.
- The reviewed production view files and appeal UI test are byte-identical between Lite and Full. The layout suites retain their existing variant differences.

## Profile statistics: finding closed

The first layout revision used `ViewThatFits` to switch the three statistics from one horizontal group to vertical rows. Each individual count-and-caption pair still had a fixed horizontal size in the final vertical fallback. A single pair wider than the available width could therefore overflow at larger accessibility sizes or with a longer translation.

The final `profileStatistic` at `ProfileHeader.swift:649` has its own horizontal fit check. It first measures the natural count-and-caption row, then falls back to a count-above-caption stack whose `fixedSize(horizontal: false, vertical: true)` respects the proposed width and permits wrapping. The outer group still uses a natural-width horizontal row when all statistics fit and vertical rows otherwise. There is no device-specific width or font-size reduction.

The following and followers buttons still append the same profile navigation destinations with the same DID. Posts remain conditional on an available post count and do not acquire a new action. Existing number formatting and `LocalizedStringKey` captions are preserved. Each statistic combines its count and caption as one accessibility element, including the fallback.

The focused layout test now requires OCR recognition of `Following`, `Followers` and `Posts` in every capture except the deliberately short view. This is useful regression coverage for the English fixture, including its accessibility text-size case. It does not independently establish maximum accessibility sizes, all translations, right-to-left rendering or unclipped count geometry; those remain rendering evidence limits, not additional source findings.

## Failed appeal: no remaining source finding

The reason field is connected to a private `FocusState`. `startSubmission` verifies the current viewer and clears keyboard focus synchronously before starting the existing submission operation. The reason binding is not reset on failure or retry.

The native form keeps one stable `appealSubmission` section containing the optional error and the submit/retry button. On a non-nil error, the handler verifies both the current viewer and the exact presented label, clears reason focus and scrolls that section to the bottom. This introduces no delayed task that could later scroll a replacement form. The error can grow vertically, and the button's title remains localized while explicitly offering `Retry Appeal` after a failure.

The existing `LabelAppealSubmission` model is unchanged: duplicate requests are refused while submitting, cancellation revokes the attempt ID, and late success/error/deferred cleanup must still belong to the same attempt. Current-viewer checks, subject ownership, success dismissal and cancellation on dismissal are retained. No report is sent by these UI tests; their fixture supplies the failing appeal transport.

The updated `testLabelMetadataAndFailedAppealPreserveReason` selects controls by stable identifiers and first proves that typing displayed the keyboard. After failure, it requires the actual error and retry control to be hittable, retry enabled, keyboard absent and both frames contained in the app window. It verifies the exact reason and captures the screenshot without an intervening tap or scroll. These assertions were read, not executed, by this reviewer.

## Remaining integration qualification

1. Build the complete Lite and Full targets with these exact source deltas.
2. Run the existing profile layout suite and inspect the newly captured narrow/accessibility images for complete captions and counts, preserving the existing navigation state checks.
3. Run `CatbirdUITests/SocialActionsUITests/testLabelMetadataAndFailedAppealPreserveReason` and inspect its immediate failed-appeal screenshot for visible error and enabled retry with the keyboard absent and reason preserved.

Source review does not establish that the keyboard animation, native form scrolling or layout renders correctly on a running device. The broader social, composer and lifecycle work was not reopened by this bounded review.

## Assessed source identity

SHA-256 values:

| File | Lite | Full |
| --- | --- | --- |
| `ProfileHeader.swift` | `0dc1c9628b98bf7cdf665905d60b720fcbac9b91e7a2da1d1fd4634de4b6085b` | Identical |
| `LabelsOnMeView.swift` | `4b9673b5477e618673a56b483e3ee1832cbce69e0c06540e0c45ede258f641c2` | Identical |
| `LabelAppealSubmission.swift` (unchanged) | `16c56d32c1707817929f8f36f02bcad33b2c888d503a3456253cd8da41d28e2b` | Identical |
| `SocialComponentLayoutTests.swift` | `ae2da194aa0d91479d8c5dc9aeb5c465e82e3d46c21aec89a362c54f60b5cd0f` | `9c7a8e994f8bfbdadb8401cfa399fcbd2228fc31ca7bbc622b7c0e77704f1fa9` |
| `SocialActionsUITests.swift` | `5f18b1e09e5aeeafe06aa1b376dd8e413736d0ae6babc54ea349901582d08a52` | Identical |
