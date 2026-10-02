# Appeal failure visibility

The appeal form retained its reason after a failed mock submission, but the software keyboard covered the failure message and retry action. The native form now clears reason-field focus when submission begins and scrolls the current failure and retry action into view together. Lite and Full contain the same focused repair and UI journey assertions. The integration lane owns the selected simulator test and screenshot verification.

Governing plan: [live feedback execution](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md).

## Implementation decision

This is a local, reversible UI correction: use SwiftUI `FocusState`, an always-present native form section, and `ScrollViewReader` with a stable section anchor. Dismissing focus on submission restores available space before a network result arrives; scrolling on a current failure makes the error and enabled `Retry Appeal` action reachable in smaller presentations. Keeping the form's native scrolling avoids fixed heights or device-specific offsets. Existing exact-attempt, cancellation, current-viewer, ownership and submission guards remain unchanged, and the reason binding is never cleared by failure or retry.

Stable accessibility identifiers identify the reason, failure and submit/retry control independently. The error-change handler checks the current viewer and exact presented label before changing focus or scrolling, so a dismissed or replaced form is not driven by an old presentation.

## Verification

Both modified Swift source/test pairs pass frontend parsing. An independent read-only source review found no blocker in the focus and stable-anchor approach. No build, live appeal, simulator run or account action was performed in this lane.

Run `CatbirdUITests/SocialActionsUITests/testLabelMetadataAndFailedAppealPreserveReason`. The fixture uses the injected failing appeal transport. The journey first proves that typing displayed the keyboard, then requires the actual failure text and retry control to be hittable, retry enabled, and keyboard absent. It checks both controls' frames are contained in the app window, verifies the reason is unchanged, and immediately captures `appeal-failure-preserves-reason` without any intervening tap or scroll. Existence alone no longer passes the failure state. The journey then cancels and retains the existing other-account ownership check.

Runtime success and the resulting screenshot are pending the integration lane's selected test run; parsing does not establish rendering or device qualification.
