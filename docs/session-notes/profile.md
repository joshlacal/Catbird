# Profile labels, appeals, and Germ implementation

This lane implements discoverable account-label inspection and the external Germ action in Catbird Lite. It retains existing label policy and uses the frozen Petrel SDK's generated profile metadata. Source changes and fixture tests are ready for the parent lane's combined build and simulator verification; parsing is verified, while compiled tests and authenticated device behavior remain open. The parent integration owner controls commits, shared full-app counterparts, simulator build slots, and phone installation.

Governing plan: [parallel execution](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md). Requirements: [LITE-007/008 feedback](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/qa/catbird-lite-live-feedback.md) and [resizability reference review](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/qa/iphone-resizability-reference-review.md).

## Source and decisions for integration

- `ProfileHeader.swift`: visible active account-label count, own/other inspector, Germ button with the supplied green logo, explicit external handoff confirmation showing destination hostname. UIApplication/NSWorkspace opens the universal link externally, allowing the OS's app-or-web fallback. No message is sent.
- `ProfileViewModel.swift`: exposes immutable `currentUserDID` to bind profile viewer relationships to their loading account.
- `UnifiedProfileView.swift`: existing own-profile overflow inspector now uses the same subscribed account-label filtering as the header.
- `AccountLabelPresentation.swift`: localized custom label definition resolution (preferred exact/base language, English, first available), issuer display, information versus warning severity, active/subscribed subject filtering and duplicate suppression.
- `LabelsOnMeView.swift`: shared own/other inspector; metadata loading per presentation/current account, raw identifiers retained if definitions fail, retry action, 300-character reason validation, preserved reason on failure, cancellation/dismissal and account-change guards.
- `ReportingService.swift`: guards ownership, current authentication, self labels, expiry and reason length; requires record URIs with CID and account DIDs without CID; sends issuer DID + `#atproto_labeler` with exact auth continuity, which binds DID and auth generation. Keeps generated request input but retains non-success HTTP JSON so the exact `AlreadyAppealed` error code is distinguishable. Other errors are not substring-classified as duplicates.
- `GermProfileAction.swift`: uses the generated `profile.associated.germ` AppView projection of `com.germnetwork.declaration.messageMe`, as the current official client does. Allows `everyone` or `usersIFollow` only when the profile owner follows the viewer. Absent/none/unknown metadata, own profiles, blocking, stale viewer and malformed/insecure URLs suppress the action. Preserves query/path, adds `/iOS` (`/web` on macOS), and appends recipient then viewer DIDs in the fragment. No MLS dependency or record write is introduced.
- `Resources/Assets.xcassets/GermLogo.imageset`: official downloadable branding asset from https://www.germnetwork.com/s/Germ-green-logo.png, linked by https://www.germnetwork.com/blog/more-support-for-your-germ-dm-button.

Provisional choice for the integration decision log: consume the already-generated AppView projection rather than duplicate PDS discovery/decoding, matching the current official Bluesky implementation. Restrict outgoing links to HTTPS with no preexisting fragment or userinfo, and require explicit confirmation showing the destination for all Germ links (including custom domains). Hide the self-profile Germ messaging action; managing/removing Germ declarations is outside the requested external-message scope. These product choices are reversible before merge by changing the pure action policy or header confirmation.

Official contract references: https://mark-germ.leaflet.pub/3mem22lhe222t; https://www.germnetwork.com/blog/more-support-for-your-germ-dm-button; reference checkout `social-app/src/screens/Profile/components/GermButton.tsx` (`profile.associated.germ`, follow direction, URL completion, custom-domain warning), `social-app/src/components/moderation/AppealForm.tsx` (issuer service suffix, exact AlreadyAppealed).

## Verification and fixture contracts

- `swift -frontend -parse` passed for all nine changed/new Swift source/test files. This is syntax evidence only.
- Expanded `LabelAppealTests` with no-network transport tests for exact issuer/account subject, record subjects, other-account rejection, changed-account rejection, detail validation, exact duplicate error mapping, unsuccessful submission and cancellation before transport.
- New `ProfileLabelAndGermTests` cover localized informational metadata/issuer, subscribed active deduplicated count, visibility/follow direction, self/blocking/stale-account suppression, malformed URL rejection, query preservation and DID escaping.
- No production mutation, report, appeal, message, or dependency/codegen operation was performed.
- Independent read-only contract research checked SDK and official client. Parent must run independent diff review; requesting the completed contracts agent for review hit the live agent thread limit.

`LabelsOnMeView(labels:targetDescription:viewerDID:reportingService:labelers:)` accepts canned detailed labelers; passing `labelers: []` suppresses network metadata loading. `ReportingService(client:reportTransport:activeAccountDID:)` accepts an async mock transport receiving generated report input and exact destination service string. The real UI requires the current lifecycle AppState identity; the DEBUG fixture should call `AppStateManager.shared.setLifecycleForTesting(.authenticated(state))` on its fake state so account controls can render safely without authentication bootstrap.

Outstanding qualification: parent build + Swift tests + running fixture at narrow/wide/short/tall/larger text; real-device universal-link installed/uninstalled behavior and authenticated subscribed label metadata remain integration gates. No successful authenticated-device behavior is claimed here.


Independent review repair: preserved Germ percent-encoded path octets while appending the optional platform hint, with exact regression coverage for `%2F`, `%3F`, `%25`, and query retention. Platform values are restricted to the documented values. Applied to Lite and the focused Full counterpart; parsing passed.

The Full counterpart is under `social/Full/Catbird` at the confirmed full base. Its `UnifiedProfileView` diff is only the account-label argument; Full Live Status, filtering and MLS/blocking features remain intact. Other owned counterpart source/test/asset files match Lite. Parent explicitly tracked the official PNG despite the repository's blanket PNG ignore.


Independent review repairs, both trees: profile-record labels at exactly `at://<profileDID>/app.bsky.actor.profile/self` now count alongside account-DID labels, including self-applied labels; unrelated post labels remain excluded. Record labels with a CID retain strongRef appeal subjects; missing-CID record labels remain non-appealable. Added own/other/profile-record/self-label regressions.

Appeal attempt lifetime now lives in `LabelAppealSubmission.swift`, a MainActor observable model with per-attempt UUIDs. Cancel invalidates ownership immediately; an older task's defer/success/error can only touch state when its UUID is current. The deterministic gated test starts A, cancels A, starts B, releases A, verifies B remains busy and rejects another submit, then releases B and observes exactly one success. The production inspector uses this model directly. Parsing passed; compiled execution remains pending the parent slot.


Bounded executable evidence: the exact production `LabelAppealSubmission.swift` and its production `LabelAppealSubmissionTests` were copied into `/tmp/catbird-profile-appeal-submission-check`, a minimal Swift 6/macOS 14 package. `swift test --package-path /tmp/catbird-profile-appeal-submission-check --jobs 2` compiled successfully and passed the single deterministic cancel/reopen/resubmit regression. This proves that production model's compiled lifecycle behavior only; Petrel/app/UI tests remain the separate parent gate. Existing taken-down-account appeals also now pass their expected account DID into the same exact-auth transport binding.


Settings integration dependency resolved at the consumer: ProfileHeader now waits for `Notification.Name("CatbirdAcceptLabelersHeaderDidChange")`, emitted by the Settings topic only after awaiting `client.setAcceptLabelers`. The event must carry the same PreferencesManager instance as object, matching `userInfo["accountDID"]`, and the actual applied `userInfo["labelerDIDs"]` array. The consumer also requires the current active profile viewer and receives on the main queue. Local subscription changes continue to filter removed labels immediately but no longer trigger a premature network fetch. **Integration must combine the Settings publisher topic for new-subscription refreshes to run.**

`ProfileLabelRefresh.swift` contains the pure event matcher, exercised by two new production `ProfileLabelRefreshTests` for owner/account/active-viewer matching and rejection of premature or unrelated events. The standalone bounded SwiftPM check now compiles the exact production helper and model and passes **3 tests in 2 suites**. Parsing passes for the modified header/helper/tests, and changes are mirrored into Full.
