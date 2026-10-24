# Catbird Circles and session continuity

Catbird's Circles client consumes the revised Spaces API through Petrel and the private Circles AppView. This integration closes stale-content, permission, capability, private-image, and gateway-session races while preserving the existing full-app navigation. Source review is closed, the signed application has executed its focused tests, and all three targeted UI cases now pass with inspected screenshots. Fresh native MLS integration remains a separate artifact and app verification gate.

Governing workspace plan: `docs/execution-plans/2026-10-23-spaces-release-implementation.md`; decisions: `docs/DECISIONS.md` in the Catbird+Petrel workspace. This source change implements the Catbird portion of that plan against upstream protocol commit `ac0c9f15392f6f0298d71dc52aa88c05036150be`. The companion backend disables private images and requires the same exact profile. External evidence paths below are relative to the isolated integration root, not this repository.

## Behavior

- Spaces calls use `spaceType`; member grants and roster results preserve actual read/write permissions.
- Circles require the exact reviewed protocol revision. Unsupported and unknown accounts cannot inherit support from a previously active account, and superseded capability probes cannot update replacement state.
- Account-scoped generation tokens retire aggregate feeds, per-Space feeds, notifications and media together. Reads begun before retirement cannot restore private content afterward. In-memory media results obey the same fence as disk and feed caches.
- Private threads stay on their Circle route through loading and navigation. A private failure cannot fall through to a public thread request.
- Private images remain unavailable until their transport is qualified. Composer submission rechecks the destination and capability, rejects private attachments before public upload, retains the draft, and never silently changes its audience. Backend image support remains disabled independently.
- Anonymous and inactive-account legacy logout notifications cannot invalidate the active account.
- A gateway authentication rejection can expire UI only while the same SDK account/credential mutation gate still protects the exact rejection context. The synchronous callback also clears local notification presentation. Later mutable credentials cannot be used to unregister push for a recovered session; explicit logout keeps its existing remote cleanup behavior.

## Verification and scope

The broad signed simulator rerun passed all 129 tests in nine Circles/auth suites. The final focused signed run passed nine gateway-session tests, including the new anonymous/inactive-account regression, and all three UI tests: supported Circles navigation, unsupported-feature hiding, and blocked private-image submission. The final `xcodebuild test` invocation exited 0 with `TEST SUCCEEDED`; the finalized result bundle is `build/Catbird/Logs/Test/Test-Catbird-2026.10.23_21-02-02--0400.xcresult` and its log is `artifacts/catbird/test-circles-auth-ui-r4.log`.

Earlier failures are retained. The initial broad run had one stale protocol literal (128/129), corrected to the profile constant in management and moderation fixtures. A UI navigation query used the wrong accessibility role and was corrected from button-only to the actual tab identifier. A later unsupported-account run reached the login screen because anonymous public requests broadcast an empty-DID logout event; the production auth handler now ignores unscoped and inactive-account events before any auth, debounce or cache mutation. The subsequent matching-account regression still expires the session. Initial unsigned runs lacked the application's keychain/application-group entitlements. Earlier failed-run diagnostic collection was stopped after completed test results were saved; those invocations are not reported as overall successes.

SwiftLint completed for all 36 changed Swift files, followed by the final auth/UI files; existing warnings remain. Independent source review covered cache/media invalidation, private-thread routing, capability gates, atomic gateway rejection and the final legacy-event scope check. The three UI screenshots were visually inspected: the supported feed displays the Family/Alice Only fixture posts; the composer retains its private Family destination and attachments, displays the image-unavailable warning and disables submission; the unsupported drawer omits Circles.

The UI scenarios use disposable presentation fixtures. They do not establish real OAuth, AppView federation, private-image transport safety or actual membership-removal behavior. The unit fixture accounts use unique keychain namespaces; the UI run uses a dedicated simulator. The app tests above use the existing v1.5.21 native MLS artifact with new Space callbacks disabled. Final native integration requires a fresh artifact and verified manifest before rebuilding and launching the app; the public native release pin remains a separately authorized release gate.

Capture exports: `artifacts/catbird/ui-r4-attachments/manifest.json`; supported `FACB27DD-45A9-4612-AD90-3F89B6EAC3CD.png`; blocked image `B043C445-5D70-4044-BBE7-E942C0F1B2D1.png`; unsupported `53D61A73-EC9B-4ED4-A8EB-7109E94CF3A4.png`. The permanent evidence bundle contains named copies.

## Custody and remaining release checks

The isolated Catbird workspace starts from `11a0053b72dc`; canonical UI changes and user simulator data are preserved. A new simulator named `Spaces release Oct23` holds this run's fixture state. The project retains its established sibling Swift-package layout; the integration manifest records the exact Petrel, overlay and MLS wrapper revisions required together. No Lite feature activation, production deployment, main-line merge or package release is included.

Before production rollout, exercise a disposable real account through Nest and the running Circles AppView: create a Circle, add a second account with restricted permissions, post/reply, remove it while requests are in flight, switch accounts, and verify stale content never reappears. Repeat deletion and recreation with fresh Space identity, confirm private image drafts remain blocked, and inspect actual device behavior. Those scenarios are not implied by local fixture screenshots or transport tests.
