# Retained Settings control audit

This audit follows Catbird Lite's retained Settings controls from their labels to storage and runtime behavior. The implementation groups related controls, removes duplicate editors and unsupported promises, and limits Appearance reset to visual customization. It preserves existing account, privacy, accessibility, language, and media values. Source inspection and focused model tests establish the findings below; authenticated server behavior and running-app layout require the combined lane's separate simulator/device evidence.

Governing scope: [parallel implementation plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md), [Lite release plan](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-09-29-catbird-1.0-app-store-plan.md), [live feedback](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/qa/catbird-lite-live-feedback.md), and [owned decisions](settings-decisions.md). The final UI action/count corrections are sealed at `2b9739ecd0ce90d5ad2e037f1a38ce1c34fc0924`. The source also includes `1b7e10060f3ae9908fb2bf7e64873ddfd7bdcb29` (interests/language) and `743fd0ae2dc1bbee4cf93c88e4f9b12da39198f1` (completed labeler-header signal), above `165284e382cb08617bc2159b1f5e1007ff7019f9`, `97a4458cb4716a6932eddf01f6b00a3e048460d8` and `b528fdc3d025a63ce50c3bb7e1ff896e54533892`, based on Lite `f0ca2f5334ac87fd53ac30f50861f296576c8051`.

## Reading this inventory

- **Local account** means the active account's `AppSettingsModel` SwiftData row. `AppSettings` setters request a debounced model save and `AppSettingsChanged` notification. Theme, font, embed and consent values additionally have UserDefaults backups; it is not accurate to claim that every local setting has that backup.
- **Synced account** means the account's `Preferences` row and cache plus a `PreferencesManager` API write. Defaults describe an absent preference, not an existing user's value. These writes were traced but not executed against a real account.
- **Device** means installation/system storage, not an independently synced account choice.
- **S** means source tracing only. **T** means an executed focused model test. **R** means running-app evidence remains with the parent lane. A control marked S is not claimed to have passed an authenticated action test.
- Navigation, preview actions, search fields, retry and confirmation buttons are included separately from persisted choices. About/Support and StoreKit controls have their own owner and report; this audit includes their entry point but does not duplicate that owner's purchase-lifecycle claims.

Primary storage sources: [AppSettingsModel](../Catbird/Features/Settings/Models/AppSettingsModel.swift), [AppSettings facade](../Catbird/Features/Settings/Views/AppSettings.swift), [PreferencesManager](../Catbird/Core/State/PreferencesManager.swift), [preference shapes](../Catbird/Core/State/Models/PreferenceModels.swift). Primary consumer sources: [FontManager](../Catbird/Core/State/FontManager.swift), [ThemeManager](../Catbird/Core/State/ThemeManager.swift), [FeedModel](../Catbird/Features/Feed/Models/FeedModel.swift), [ThreadManager](../Catbird/Features/Feed/Services/ThreadManager.swift), [VideoCoordinator](../Catbird/Features/Feed/Views/VideoCoordinator.swift), [URLHandler](../Catbird/Core/Networking/URLHandler.swift).

## Settings home and ownership

[SettingsView](../Catbird/Features/Settings/Views/SettingsView.swift) remains a native Form inside the existing navigation owner. Sections now follow user intent.

| Control | Scope, action and consumer | Visibility / verification |
| --- | --- | --- |
| Account header / account switcher | Opens existing account switcher; active authentication is managed by AppStateManager, not reset by this work | Existing account/header states; S, R |
| Account; Privacy & Security | Open account identity and privacy/security pages | Always retained; S, R |
| Content & Media; Moderation; Feed Filters | Open content/discovery, safety, and local filter controls | Always retained; S, R |
| Appearance; Accessibility | Open visual customization and accessibility pages | Always retained; S, R |
| Notifications and On/Off summary | Existing NotificationManager registration/master status; summary does not assert push delivery | Always retained; S, R |
| Help | Opens help browser and support links | Always retained; S, R |
| Show Tips Again | `onboardingManager.resetAllOnboarding()` resets onboarding display flags only | Explicit action; no account/content reset; S |
| About & Support | Opens existing About page, whose tips implementation is owned by support worker | Always retained; S; support lifecycle evidence separate |
| Open Source Licenses | Read-only bundled license information | Always retained; S |
| Service Providers | Opens Advanced endpoint draft editor | Always retained; S, R |
| System Logs and version row | Diagnostics view/version metadata | DEBUG only; not a release setting |
| Sign Out | Existing logout flow, with progress/error handling; authentication/account action | No logout executed in this lane; S |

## Appearance

[AppearanceSettingsView](../Catbird/Features/Settings/Views/AppearanceSettingsView.swift) is the sole editor for custom typography. Preview text now uses the production app font modifiers, and preview cards expand with their text instead of imposing a fixed content height.

| Label / key | Default | Scope and write | Runtime consumer | Visibility / verification |
| --- | --- | --- | --- | --- |
| App Theme / `theme` | System | Local account; facade/model + backup | AppState theme application → ThemeManager | Always; S, T for reset, R |
| Dark Mode Style / `darkThemeMode` | Dim | Local account | ThemeManager dim/black backgrounds | Dark theme, or System while system is dark; S, T, R |
| Accent Color / `accentColor` | Catbird/default | Local account | ThemeManager accent; root owns the separately reviewed AppState hash invalidation repair | Always; choices expose selected accessibility trait; S, T, R |
| App Icon | Default | Device/system `setAlternateIconName`; independent of appearance model | Installed application icon | iOS and `supportsAlternateIcons`; Default and Classic; preserved by reset; S |
| Font Style / `fontStyle` | System | Local account | FontManager and post font modifiers | System, Serif, Rounded, Monospaced; S, T, R |
| Font Size / `fontSize` | Default | Local account | FontManager sizing | Small, Default, Large, Extra Large; S, T, R |
| Line Spacing / `lineSpacing` | Normal | Local account | FontManager/TappableTextView | Tight, Normal, Relaxed; S, T, R |
| Text Scaling & Accessibility | None | Navigation only | Accessibility page owns Dynamic Type, contrast, motion, reading aids | Replaces duplicate editors and broad preset buttons; S, R |
| Reset Appearance… / Reset Appearance / Cancel | No automatic reset | Confirmation → `AppSettings.resetAppearanceToDefaults` → model reset/save | Resets exactly theme, dark style, accent, font style/size/line/letter spacing | Explicit scope text; all other values and app icon preserved; S, T, R |

The model still contains `letterSpacing` (Normal by default), which is consumed by FontManager but has no current visible picker. The appearance reset includes this typography value. Dynamic Type and its maximum size are deliberately excluded from reset even though they affect text presentation.

## Accessibility

[AccessibilitySettingsView](../Catbird/Features/Settings/Views/AccessibilitySettingsView.swift) no longer contains duplicate font or autoplay editors, a nonfunctional long-press slider, or a misleading device-undo switch.

| Label / key | Default | Scope and write | Runtime consumer | Visibility / verification |
| --- | --- | --- | --- | --- |
| Require Alt Text Before Posting / `requireAltText` | Off | Local account | Composer submit validation checks every image/video alt text | Always; existing runtime-wiring tests cover predicate; S, R |
| Display Larger Alt Text Badges / `largerAltTextBadges` | Off | Local account | Image-grid badge metrics | Always; existing deterministic metrics test; S, R |
| Reduce Motion / `reduceMotion` | Off | Local account | MotionManager and supported transition helpers | Copy accurately limits claim to supported animations; S, R |
| Prefer Cross-fade Transitions / `prefersCrossfade` | Off | Local account | MotionManager transition choice | Disabled unless Reduce Motion is on; S, R |
| Video Autoplay | None | Navigation only | Content & Media's sole autoplay editor | Replaces duplicate toggle; S, R |
| Increase Contrast / `increaseContrast` | Off | Local account | Adaptive colors/borders and contrast-aware views | Preview retained; source coverage is selective, not a global override; S, R |
| Bold Text / `boldText` | Off | Local account | App font modifiers | Preview retained; source coverage is selective; S, R |
| Font Style, Size & Spacing | None | Navigation only | Appearance | Replaces duplicate pickers; S, R |
| Dynamic Type / `dynamicTypeEnabled` | On | Local account | FontManager + UIFontMetrics sizing | Hidden on Catalyst; native macOS ignores the setting; S, T preservation, R |
| Maximum Text Size / `maxDynamicTypeSize` | Accessibility Medium | Local account | FontManager and UIKit cap | Shown when Dynamic Type is on; raising cap changes nothing until system size exceeds previous cap; S, T preservation, R |
| Show Reading Time Estimates / `showReadingTimeEstimates` | Off | Local account | PostReadingTime/PostView | Label appears at 100+ words; footer now says so; existing predicate test; S, R |
| Highlight Links / `highlightLinks` | On | Local account | Post attributed-link presentation | Always; existing attributed-string tests; S, R |
| Link Style / `linkStyle` | Color Only | Local account | Post link styling/cache | Color, underline, both; disabled when highlight is off; S, R |
| Confirm Social Actions / `confirmBeforeActions` | Off | Local account | Account/thread mute and profile unfollow paths | Clarifies actual actions; deletion/block already always confirm; S, R |
| Disable Haptic Feedback / `disableHaptics` | Off | Local account + facade sync to `PlatformHaptics.isEnabled` | PlatformHaptics | Always; source no-op on unsupported platform; appearance reset preserves it; S, T preservation, R |

## Content & Media

[ContentMediaSettingsView](../Catbird/Features/Settings/Views/ContentMediaSettingsView.swift) retains its name for the recovery instructions shown by Feeds and Search. Local controls remain usable when account preferences cannot be fetched. Account feed/thread editors require the strict Settings refresh helper, which throws if the actual PreferencesManager client is unavailable; the generic manager's offline-success path is not accepted as a verified remote refresh.

| Label / key | Default | Scope and write | Runtime consumer | Visibility / verification |
| --- | --- | --- | --- | --- |
| Autoplay Videos / `autoplayVideos` | On | Local account | VideoCoordinator | Sole editor; explicit GIF exception (GIFs always autoplay); S, R |
| Open Links In-App / `useInAppBrowser` | On | Local account | URLHandler's internal/external browser choice | Always; S, R |
| Show Trending Topics / `showTrendingTopics` | On | Local account | Search Discovery and feed interstitials | Footer explicitly says feeds and Search for this account; S, R |
| Show Trending Videos / `showTrendingVideos` | On | Local account | Search Discovery and trending video feed content | Same scope; S, R |
| Your Interests | Empty if absent | Navigation to account interests editor | PreferencesManager/interests recommendation path | Count only after successful load; no perpetual spinner on failure; S, R |
| Hide All Replies / `feedViewPref.hideReplies` | Off | Synced account; explicit user binding | FeedModel → FeedTuner; wire `home` preference | Loaded account only; disabled during write/pending retry; S, R |
| Hide Replies to Users You Don't Follow / `hideRepliesByUnfollowed` | Off | Synced account | FeedTuner user/follow filtering | Disabled while Hide All Replies is on; same write gating; S, R |
| Hide Replies Below Minimum Likes / `hideRepliesByLikeCount` presence | Off/nil | Synced account; OFF passes `clearReplyLikeThreshold: true` | FeedTuner | Disabled with Hide All Replies; S, T for update semantics, R |
| Minimum likes stepper | 2 when enabling; saved value otherwise | Synced account, 0…100 UI range | FeedTuner | Only while threshold enabled and replies not all hidden; zero is valid; S, T, R |
| Hide Reposts / `feedViewPref.hideReposts` | Off | Synced account | FeedModel/FeedTuner | Loaded account only; local Quick Filters can additionally hide; S, R |
| Hide Quote Posts / `feedViewPref.hideQuotePosts` | Off | Synced account | FeedModel/FeedTuner | Same scope distinction; S, R |
| Thread Sort Order / `threadViewPref.sort` | Hot legacy key, displayed Top | Synced account; successful save updates local `threadSortOrder` | ThreadSortAPIMapper/ThreadManager | Top, Latest, Oldest; legacy Hot is Top's same API behavior, not a second option; S, R |
| Threaded Replies View / `threadedReplies` | Off | Local account | ThreadManager/display layout | Available independently of server fetch; S, R |
| Auto-Load Hidden Replies / `showHiddenPosts` | Off | Local account | UIKitThreadView hidden-reply loading | Off leaves explicit Show More Replies; S, R |
| Hide posts in non-preferred languages / `hideNonPreferredLanguages` | Off | Local account | FeedModel and Search filtering | Always; S, R |
| Show language indicators on posts / `showLanguageIndicators` | On | Local account | Post language badge predicate | Only posts with languages show indicator; S, R |
| Manage Languages | None | Navigation | Language page | Always; S, R |
| Enable Embedded Players / `useWebViewEmbeds` | On | Local account | ExternalEmbedView player gate | Honest user-facing name replaces WebView implementation name; S, R |
| External Media Preferences | None | Navigation | Provider consent page | Remains accessible when players are disabled so stored permissions can still be inspected/changed; S, R |
| Retry Loading Preferences | None | Explicit read retry → strict remote refresh → load state | PreferencesManager | Only failed load; no preference write from loading; S, R |
| Retry Saving Preferences | Retains attempted selection | Resubmits failed feed/thread operation; errors cleared only after success | Same preference writer | Pending edits lock further synced edits. Returning from child page cannot overwrite pending draft with a fetch. No real write exercised; S, R |

The former unconfirmed Content & Media reset is removed. It mixed local playback/discovery resets, consent reset, and remote account filter writes. No existing preference is migrated or reset merely by opening the revised page.

## External media consent

[ExternalMediaPreferencesView](../Catbird/Features/Settings/Views/ExternalMediaPreferencesView.swift) owns one tri-state picker per provider. Every provider defaults to **Ask Before Playing**; options are Ask Before Playing, Always Allow, and Always Block. Pickers write `externalMediaConsents[provider]` in the account model and scoped consent backups. ExternalEmbedView reads those values; Tenor consent also gates composer GIF access. This is a local account privacy choice, not a Bluesky server setting. Source reviewed; no provider connection or user consent was changed by the agent.

| Retained picker labels / provider keys | Visibility / verification |
| --- | --- |
| YouTube / `youtube`; YouTube Shorts / `youtubeShorts`; Vimeo / `vimeo`; Twitch / `twitch` | Always; accessibility label includes provider playback; S, R |
| Spotify / `spotify`; Apple Music / `appleMusic`; SoundCloud / `soundcloud` | Always; S, R |
| GIPHY / `giphy`; Tenor / `tenor`; Klipy / `klipy` | Always; S, R |
| Flickr / `flickr`; Bandcamp / `bandcamp` | Always; S, R |
| Allow All Providers | Explicitly writes Allow to each provider; existing behavior, no live action performed; S |
| Ask Before Playing (Reset All) | Resets only these 12 provider consents to undecided; does not reset media playback or accounts; S |
| Block All Providers | Explicitly writes Block to each provider; existing behavior; S |

## Inactive, hidden, and duplicate controls

| Stored value or old editor | Finding | Implemented treatment |
| --- | --- | --- |
| Scan for Sensitive Content / `sensitiveContentScanningEnabled = true` | No Lite reader outside Settings; promised on-device chat-image scan has no implementation in this build | Hide control; preserve model, key, copy/migration behavior. Full counterpart must evaluate actual MLS consumer separately. |
| Long Press Duration / `longPressDuration = 0.5` | No consumer outside Settings; gestures use fixed/default durations | Hide slider and unsupported context-menu claim; preserve key. |
| Shake to Undo / `shakeToUndo = true` | Only consumer gates error-shake animation in View+Shake; no device undo action | Hide misleading switch; preserve key. |
| Prioritize Users I Follow / `prioritizeFollowedUsers = true` | Neither serialized in ThreadViewPref nor used by local sorting | Hide editor; preserve value; thread sort remains live. |
| `showSavedFeedSamples = false` | Stored but no retained consumer/control | No new editor; preserved. |
| `displayScale = 1.0` | Selective consumers, no visible retained picker | No new editor; preserved by appearance reset. |
| `letterSpacing = normal` | Actual typography consumer, no current picker | Included in typography reset only; no new speculative UI. |
| Font/size/spacing editors in Accessibility | Same keys as Appearance | Replace with Appearance link. |
| Dynamic Type editors / broad accessibility presets in Appearance | Same keys as Accessibility; presets silently changed multiple scopes | Replace with Accessibility link; remove preset controls. |
| Autoplay editor in Accessibility | Same `autoplayVideos` as Content & Media | Replace with Content & Media link. |
| Muted Words on Settings home; block/mute editors under Privacy | Duplicate moderation entry/edit surface | Moderation is canonical; Privacy offers navigation link. |
| Synced Hide Replies from Not Followed in Feed Filters | Same server preference as Content & Media; local load failure fell back to writable defaults | Replace with Account Feed Filters navigation link. Local Quick Filters retained. |

## Account and privacy/security

These are account or authentication actions, distinct from display settings. No action in this table was executed with the user's account. Sources: [Account](../Catbird/Features/Settings/Views/AccountSettingsView.swift), [account sheets](../Catbird/Features/Settings/Views/AccountSettingsHelpers.swift), [Privacy & Security](../Catbird/Features/Settings/Views/PrivacySecuritySettingsView.swift), [Automation Label](../Catbird/Features/Settings/Views/AutomationLabelSettingsView.swift), [Activity Privacy](../Catbird/Features/Settings/Views/ActivityPrivacySettingsView.swift).

| Control(s) | Default / persistence and write | Consumer / visibility / verification |
| --- | --- | --- |
| Change Handle | Current server identity; opens draft editor | Account/profile identity; disabled loading/updating; S |
| Bluesky Handle / Custom Domain; Username; service-domain picker; custom-domain field | Draft defaults Bluesky, empty username, bsky.social; server describeServer provides choices | Domain picker only if multiple choices; custom domain requires resolution to current DID; S |
| Verify DNS Record; Update; Cancel | Verify uses resolveHandle; Update requests identity permission and calls updateHandle; Cancel discards draft | Account/server identity; no actual change tested; S |
| Manage Email; New Email | Current session email is authoritative; empty draft retains current email | Opens server email update flow; S |
| Require Email 2FA at Sign-In, or Keep current setting / Enabled / Disabled | Current emailAuthFactor; unknown state uses Keep current | Toggle if known, picker if unknown; final updateEmail writes account setting; S |
| Email Update / Confirm / Cancel; Confirmation Code / Resend Code | Transient draft/code; server challenge decides required code entry | Explicit account email/2FA write only on confirmation; S |
| Send Verification Email | Current unverified email | Visible only for authorized, nonempty, unverified email; sends account email, not exercised; S |
| Automated Account (Bot) | Profile bot self-label; absent means Off | Writes profile self-label preserving other labels; updates profile display; disabled loading/saving; S |
| Export Repository Data | No preference | Public repository getRepo → native CAR exporter; retained account action, not deferred repository-browser feature; no export performed; S |
| Deactivate Account / Reactivate Account | Current server account status | Deactivation requires exact DEACTIVATE text, account-status permission, deactivateAccount then logout; reactivate only for deactivated status; S |
| Biometric authentication (Face ID / Touch ID / supported name) | Off; device standard-defaults biometric_auth_enabled | Enabling authenticates; app lifecycle locks; shown only when available; S |
| Enable Email 2FA / Disable Email 2FA; Enable / Cancel; disable code / Resend / Disable / Cancel | Server account emailAuthFactor | Requires verified nonempty email; disabling requires challenge token; S |
| Logged-Out Visibility | Profile !no-unauthenticated absent means visible; local model is cache only | Reconciles profile self-label preserving unrelated labels; server governs visibility; disabled loading/saving; existing predicate tests, no live write; S |
| Ask apps to hide my posts from algorithmic recommendations | Off if declaration absent | Writes app.bsky.actor.contentVisibilityDeclaration/self; advisory policy for consuming apps, not a local filter guarantee; S |
| Activity Privacy → Anyone who follows me / Only followers who I follow / No one | followers if declaration absent/unknown | Writes app.bsky.notification.declaration/self.allowSubscriptions; disabled load/save, rollback on failure; S |
| Credit Repost Discovery / enableViaAttribution | On; local account model | Like/repost record attribution to the account whose repost led to discovery; renamed from ambiguous Attribution Tracking; S |
| Blocked & Muted Accounts | None | Navigation to canonical Moderation editor; no privacy-page duplicate editor; S, R |
| Error OK / action Cancel buttons | Transient UI only | Dismiss errors or pending confirmations; no setting reset; S |

## Moderation and its subpages

Sources: [Moderation hub and account/labeler actions](../Catbird/Features/Settings/Views/ModerationSettingsView.swift), [labeler preferences](../Catbird/Features/Settings/Views/LabelerSettingsView.swift), [post interaction defaults](../Catbird/Features/Moderation/Views/DefaultPostInteractionSettingsView.swift), [verification](../Catbird/Features/Moderation/Views/VerificationSettingsView.swift), [muted words](../Catbird/Features/Feed/Views/MuteWordsSettingsView.swift), [lists](../Catbird/Features/Lists/Views/ListsManagerView.swift).

| Control(s) | Default / persistence and write | Consumer / visibility / verification |
| --- | --- | --- |
| Post Interaction Settings; Verification Badges; Muted Words & Tags; Moderation Lists; Muted Accounts; Blocked Accounts | Navigation | Account-scoped safety editors below; S |
| Adult Content | Off if absent; account adultContentPref | UI permits only turning Off; enabling occurs in official Bluesky. Feed filtering/overlays consume preference; S |
| Adult Content / Sexually Suggestive / Graphic Content / Non-Sexual Nudity, each Show / Warn / Hide | Warn if absent; account contentLabelPrefs | Visible only while adult content enabled; FeedModel/ContentFilterService and content overlays consume; S |
| Preview Show content | Transient reveal only | Changes sample preview, not account policy; S |
| Labeler Preferences; subscribed labeler detail; Add Labeler | Navigation / subscription management | Add Labeler is now outside the empty/loading subscription-list branches and remains available after the account preferences load; S |
| Remove Unavailable Labelers → Remove / Cancel | Explicit removal of missing subscribed DIDs from account preferences | Conditional missing-service list and confirmation; no removal executed; S |
| Everybody / Nobody / Specific Users | Everybody if postInteractionSettingsPref absent | Account threadgate defaults read by new composer; immediate server preference writer; S |
| Users you follow / Your followers / Mentioned users; user-list selections | First custom draft true / false / true, empty lists; existing stored rules override | Only Specific Users; account threadgate defaults; S |
| Allow quote posts | On if absent | Account postgate embedding defaults, consumed by composer; S |
| Show verification badges | On when hideBadges nil/false | Writes verificationPrefs + runtime manager flag; VerificationBadge/author surfaces consume; disabled saving, rollback on error; S |
| Add new mute word; plus or Return | Empty draft; persisted word list empty if absent | Adds content-targeted word without actor restriction/expiry, server preference and local MuteWordProcessor; rejects empty/duplicate; S |
| Search mute words | Empty query; transient | Filters local displayed list only; S |
| Muted-word trash/context Delete → Delete / Cancel; iOS swipe Delete; Retry | Deletes selected account muted word; swipe currently immediate, other routes confirm | Local processor and account preference update; Retry reloads; S |
| Per-account Unmute / Unblock | Server graph records; no boolean default | unmuteActor or delete block record; disable operation and remove row; S |
| Per-labeler Adult / Suggestive / Graphic / Nudity Show / Warn / Hide | Labeler-scoped value → global value → Warn | Account preferences carry labeler DID; filtering/overlays consume; official provider always included independently; S |
| Labeler DID / Add Labeler | Empty draft; disabled empty/busy | Adds account subscription; atproto-accept-labelers header selects services; S |
| Enable Labeler / Remove Labeler | Enabled in current subscribed-detail list | Account subscriptions/header; default service remains independently included; maximum 19 custom + official; S |
| Lists search; Create Your First List / plus; list navigation; Edit List / Manage Members / Delete → Delete / Cancel | Server account list records; drafts transient | ListsManager/ListManager; create name required; source only; S |
| List name, optional description/photo; Choose Photo / Remove; List Type Curated / Moderation / Reference; Create / Cancel | Curated default; empty name prevents create | Explicit server list creation/edit; no list/photo action performed; S |
| Refresh / load-error Retry / error OK | Explicit read retry or transient dismissal | No automatic account reset; S |

`PreferencesManager.acceptLabelersHeaderDidChange` is a completed-header signal for the social/ProfileHeader owner. It posts only after the client's `setAcceptLabelers` await finishes, with `object` equal to the manager and `userInfo` containing the account DID captured before the await and the applied labeler DID array. No-client deferral emits no signal. This avoids describing an early subscription observation as already-applied request-header state; it does not change moderation policy or add a remote write.

## Notifications

Source: [NotificationSettingsView](../Catbird/Features/Settings/Views/NotificationSettingsView.swift) and [NotificationManager](../Catbird/Features/Notifications/Services/NotificationManager.swift). Source trace is separate from the push lane's delivery work; On is not a delivery receipt.

| Control(s) | Default / persistence and write | Consumer / visibility / verification |
| --- | --- | --- |
| Enable All Notifications | Effective OS registration + account App Group masterPushNotificationsEnabled key; missing key true, display false while initialization runs | Enable requests permission/registers; disable unregisters; progress gating; S |
| Enable in Settings → Open Settings / Cancel | No app preference | System permission screen when permission denied; S |
| Turn Off Notifications | Explicit master disable | Shown for registration failure; replaces misleading Try Again Later label that already disabled notifications; S |
| Enable | Explicit permission/setup action | Shown unknown/disabled; S |
| Direct Messages | On if absent; account-local chatNotificationsEnabled plus server chat.push | iOS only, visible enabled/registered; separate local/server state requires delivery/reconciliation qualification; S |
| Mentions, Replies, Likes, New followers, Reposts, Quotes, Likes of your reposts, Reposts of your reposts | Each defaults In-App On, Push On, Everyone when server prefs absent | Each editor writes account notification preference through gateway get/putPreferencesV2; existing field mapping tests; S |
| In-App / Push Notifications for each category | Immediate account preference save | Links remain accessible when master off; client list enforcement is absent from the inspected consumer path (see gap below); S |
| Show from: Everyone / People I follow | Everyone fallback | Available for the eight filterable categories; disabled only when both channels off; S |
| Activity from others: In-App / Push Notifications | Both On fallback | subscribedPost account preference; no audience picker; S |
| Everything else: In-App / Push Notifications | Both On fallback | Groups starter-pack joined, verified, unverified and rewrites them to one common setting; no audience picker; S |

## Language, interests, local filters, advanced and help

Sources: [Language](../Catbird/Features/Settings/Views/LanguageSettingsView.swift), [Interests](../Catbird/Features/Settings/Views/InterestsSettingsView.swift), [Feed Filters](../Catbird/Features/Feed/Views/FeedFilterSettingsView.swift), [filter model](../Catbird/Features/Feed/Models/FeedFilterSettings.swift), [Advanced](../Catbird/Features/Settings/Views/AdvancedSettingsView.swift), [Help](../Catbird/Features/Settings/Views/HelpSettingsView.swift).

| Control(s) | Default / persistence and write | Consumer / visibility / verification |
| --- | --- | --- |
| App Language / System Default / language selection | System; device-global app-group appLanguage / standard AppleLanguages, plus local model field | AppLanguageManager changes localization; menu/system text; S |
| Primary Language / language selection | en; account-local model and scoped defaults | Ensures primary is in content languages; copy now states account/on-device Catbird scope. Current serializer does not send language fields to other apps; S |
| Content Languages / language rows | [en]; account-local model/scoped defaults | Feed/Search language filtering; primary and last language cannot be removed; immediate persistence; S |
| Language search; Show All Languages; suggested/recent language rows | Empty search; 62-language catalog, initial ten popular; max five device-global recent languages | Navigation/filter convenience, not independent account preference; S |
| Content-language Done / xmark | Transient dismissal; changes already saved | Done replaces misleading Cancel. Select All confirmation, where presented, explicitly selects all catalog languages; S |
| Edit Interests; Retry; save-error OK | Empty list if absent; account interestsPref | Edit disabled loading/load failure; retry reads account preferences; S |
| Interest picker: Art, Books, Business, Comedy, Design, Education, Environment, Fashion, Fitness, Food, Gaming, Health, Movies, Music, News, Photography, Politics, Programming, Science, Sports, Technology, Travel | Transient selection seeded from account interests | Cancel discards picker draft; Save submits exact list; recommendation matching consumes tags; S |
| Interest Save / Cancel | Account/server-first specific preference writer | Empty list is valid by lexicon; add/remove operate on latest server snapshot; local update follows server success; four mocked manager invocations await combined app test execution; S |
| Account Feed Filters | None | Opens canonical Content & Media editor; no duplicate server preference write here; S, R |
| Quick Filters: Hide Reposts / Hide Replies / Hide Quote Posts / Hide Duplicate Posts / Only Text Posts / Only Media Posts / Hide Link Posts / Filter by Language | Only Duplicate defaults On; account-local App Group enabled IDs | FeedModel/FeedTuner; immediate local write; explicit footer distinguishes unsynced local rules from account settings. Combinations are permitted; S |
| AppView: Bluesky PBC / Blacksky / Custom; Custom AppView DID | SDK current account service; default Bluesky | Local staged draft; Custom field conditional; save persists service DID for social-data routing; S |
| Chat: Bluesky PBC / Custom; Custom Chat DID | SDK current account service; default Bluesky | Local staged draft; Custom field conditional; save persists ordinary Bluesky DM routing; S |
| Use Default Providers | Sets only endpoint drafts to standard Bluesky DIDs | Does not save until Save Changes; label replaces broad Reset to Defaults; S |
| Save Changes; success/error OK | Nonempty did: fields required; SDK updateAndPersistServiceDIDs | Per-account endpoint persistence, explicit save; no endpoint changed in this lane; S |
| FAQ web view | No persisted app choice | Live web-provided content cannot be exhaustively inventoried from Swift source; no browser action tested; S |
| Contact Catbird Support | Plist SupportURL, otherwise SupportEmail | Link hidden if neither configured; external page/mail composition, no message sent; S |
| Contact Bluesky Support | Zendesk link | External support page, no message sent; S |
| DEBUG System Logs search/filter/refresh/share/clear UI | Diagnostic local state/log access | DEBUG-only surface, excluded from release preference qualification; no logs exported or cleared by this worker |

## Open blocking behavior and remaining evidence limits

- **Local persistence failure repaired in source; runtime qualification pending:** AppSettings now exposes an explicit unavailable state and Retry Loading, gating only local controls that need its store. Failed saves restore confirmed values and display the exact retained attempt with Retry Saving. Private SwiftData contexts isolate writes from unrelated shared-context drafts; differential retry preserves unrelated concurrent values. No durable fallback, account-store migration policy, or automatic reset was added. The focused failure tests and running-app boundaries are recorded below.
- **OPEN BLOCKING — In-App notification policy:** the inspected category/audience controls do not reach the visible list consumer; the concrete integration gap is detailed below. Integration owns assignment and remediation. Direct-message local/server preference reconciliation remains with the integration/push owners; no live delivery claim is made.
- Typography modifiers cover supported SwiftUI and UIKit surfaces, but main-post SelectableTextView bypasses some app typography choices. That consumer belongs to the relevant screen owner; this audit does not claim universal font/contrast coverage.
- Default Duplicate filtering can be active before FeedFilterActiveFilters is populated. Settings home now counts the actual enabled filter values, including that default, rather than stale stored IDs.
- App Icon is installation-wide, and app language is device-global. Most AppSettings values are per-account. These differences are intentional scope disclosures rather than a migration of user values.

## Open blocker: In-App notification consumer gap for integration

The label **In-App** promises to include or exclude that activity category from Catbird's visible notifications. **Show from: People I follow** promises to restrict that category to followed authors. The master switch's own description is push-only; it must not be repurposed as an in-app master.

The following source chain establishes a missing connection, not a deployed-system test:

1. [Category In-App bindings](../Catbird/Features/Settings/Views/NotificationSettingsView.swift:443) write `preference.list`; [audience](../Catbird/Features/Settings/Views/NotificationSettingsView.swift:469) writes `include`. Plain/Everything Else categories use the same list field at lines 515 and 571.
2. [NotificationManager's preference writer](../Catbird/Features/Notifications/Services/NotificationManager.swift:783) calls putPreferencesV2. [Endpoint routing](../Catbird/Features/Notifications/Services/NotificationManager.swift:453) sends six push/settings endpoints to Nest; it does not route listNotifications as a preference-aware local list service.
3. [Nest push handler](/Users/joshlacalamito/Developer/Catbird+Petrel/nest/catbird/src/handlers/push.rs:93) calls [PushPreferences.patch](/Users/joshlacalamito/Developer/Catbird+Petrel/nest/catbird/src/services/push/preferences.rs:65), which reads/updates Nest's database document and does not synchronize the choice to upstream Bluesky. [Preference routes](/Users/joshlacalamito/Developer/Catbird+Petrel/nest/catbird/src/routes/atproto.rs:131) intercept get/put; listNotifications falls through the [generic proxy](/Users/joshlacalamito/Developer/Catbird+Petrel/nest/catbird/src/routes/atproto.rs:155).
4. [NotificationsViewModel's request](../Catbird/Features/Notifications/ViewModels/NotificationsViewModel.swift:328) sends reasons, limit, and cursor. Reasons come only from All/Mentions tabs at line 190. [Response consumption](../Catbird/Features/Notifications/ViewModels/NotificationsViewModel.swift:355) groups every returned notification without consulting category list/include. Later pages retained during refresh at line 374 are not re-evaluated by a preference observer either.

Consequently, disabling Likes → In-App or choosing followed authors does not change this client's list through the inspected Catbird/Nest code path. Upstream could apply its own independently stored policy, but these Catbird controls are not connected to that store. NotificationManager, NotificationsViewModel, and Nest were not edited by this worker; integration owns scoping and remediation.

Meaningful bounded fixtures should cover mixed `list: false, push: true` and the inverse; category lists with followed/unfollowed/missing-viewer authors and an explicit missing-data policy; and preference changes after pagination with older retained pages re-evaluated. Existing serialization/summary and grouping tests do not exercise this policy chain. The source-only report was sent to integration before final audit handoff.

## Focused checks and evidence boundaries

The bounded host fixture copied the exact `AppSettingsModel.swift` and `ExternalMediaPreferences.swift` sources and the production reset test methods. It also extracted the exact `FeedViewPreference` data shape and `applyingFeedViewChanges` production helper into a minimal wrapper; it did not compile the whole PreferencesManager or app. Three Swift Testing cases passed: all nonappearance values/provider consents survive reset, save/refetch through an independent SwiftData context preserves the other account, and threshold omission/clearing/reenabling/zero preserve the expected data. The fixture uses an in-memory SwiftData store and does not modify the user's preferences.

Evidence: [bounded test log](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/settings-control-check/test.log), [fixture package](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/settings-control-check/Package.swift), [app test additions](../CatbirdTests/SettingsRuntimeWiringTests.swift). The app suite additionally includes strict missing-client refresh coverage and four mocked interests manager invocations: empty via remove, empty via replace, failed-write preservation, and stale-local add against newer server tags. Those app cases await the parent lane's build/test execution. Source parsing passed for edited Swift files. SwiftLint exited successfully under repository policy and reported style/size warnings in existing large files and the enlarged test suite; this is not a zero-warning claim.

The parent owns the combined Settings/Support fixture, Xcode build slot, app tests, runtime screenshots, and physical-phone integration. Required runtime checks: Settings groups and routes; Appearance reset confirmation/cancel/confirm with a seeded second account; normal and accessibility text sizes; Appearance preview expansion; Content & Media offline error/retry without blocking local toggles; explicit save-failure retry with mocked account service; support unavailable/loading states. No authenticated account preference mutation, purchase, external message, logout, account change, or physical-phone action was performed by this worker.

## Local persistence failure followup

Sources: [AppSettings persistence coordinator](../Catbird/Features/Settings/Views/AppSettings.swift), [field-copy and migration helpers](../Catbird/Features/Settings/Models/AppSettingsModel.swift), [shared failure/retry section](../Catbird/Features/Settings/Views/SettingsPersistenceStatusSection.swift), and [failure-path tests](../CatbirdTests/AppSettingsPersistenceFailureTests.swift). The implementation follows the [local persistence decision](settings-decisions.md#make-local-storage-failure-explicit-without-replacing-account-storage).

| State / action | Visible behavior | Persistence and runtime contract |
| --- | --- | --- |
| Initial fetch failure / Retry Loading | Local Settings explanation; dependent toggles/pickers disabled; Retry Loading remains enabled | No reset or backup writes; retry loads the saved account row and publishes a confirmed-change notification for runtime theme/font/browser consumers |
| Save failure / Retry Saving | Last confirmed values return; attempted settings and readable values are listed; further dependent edits disabled | Failed attempt and its baseline remain in memory; fresh-row differential merge on retry; untouched fields and provider choices survive concurrent edits |
| Account change while work is deferred | New account uses its own values | Captured DID/generation reject stale callbacks; configuring another account clears prior pending work; global effects additionally require active account-instance ownership |
| Repeated same-account initialization | Confirmed values reload; pending attempted values remain separately available | Original attempt baseline is retained rather than replaced, so retry does not overwrite newer unrelated fields |
| Language persistence | Selection uses the same local failure status | Language effects coalesce and run only after commit, using confirmed values; Retry from Settings home still owns the deferred action |
| Other Settings actions | About, support, account/security, app icon and server-only controls remain usable | No Form-wide disable; local guards apply to Appearance, Accessibility, local Content & Media, external-player consents, language selection, and Credit Repost Discovery only |

Independent source review counted all 42 model fields, confirmed guard-before-mutation on all 41 computed setters and explicit mutation methods, checked consent-key merging and absence of eager failed-write backups, and found no remaining concrete source issue. This does not establish full-app execution or physical-device behavior.

Bounded verification passed: the exact production AppSettings, AppSettingsModel, and ExternalMediaPreferences sources compiled against SwiftData in a host Swift package. The new AppSettingsPersistenceFailureTests suite passed all 12 tests / 15 scenarios; the package also ran one bootstrap smoke test. Coverage includes failed fetch and retry publication, failed save/backup/effect suppression, rollback and retained retry values, same-account reinitialization, stale deferred saves and reentrant retry-fetch account changes, inactive/replaced owners, coalesced effects, unrelated shared-context dirty rows/inserts, concurrent field/provider edits, failed new-row/legacy migration, and all 42 values including custom strings and unknown provider entries.

Evidence: [host test log](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/settings-persistence-check/test.log), [fixture package](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/settings-persistence-check/Package.swift), [UI-boundary stubs](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/settings-persistence-check/Sources/Catbird/BoundaryStubs.swift), [lint output](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/settings-persistence-check/swiftlint.log). The fixture substitutes AppState/lifecycle/theme/font/haptics boundaries; it does not establish the real app's runtime manager or rendered UI behavior. Parent-owned app fixtures/tests and simulator screenshots remain required, including the actual FontManager update after load retry and unrelated About navigation while local controls are unavailable. Edited Swift source parsing passed; SwiftLint exited 0 with repository-policy size/style warnings.

Full-app port guidance: preserve Full-only stored fields in copySettings and its baseline comparison, including retention/scanning; guard their controls with canEditPersistedSettings. Retention side effects must use afterPendingSave(key: "messageRetention") and check active account identity plus final confirmed policy before destructive cleanup. Preserve existing real MLS scanning consumers. The Lite field inventory must not replace Full's model schema.

The final failed-refetch regression additionally changes the stored font externally before Retry Loading. It verifies that the loaded font and old saved theme become visible, the retained draft description stays unchanged, and exactly one load-refresh event occurs with zero pending-write effects. Retry Saving then preserves that font, applies the attempted theme, and emits a separate save event with the effect. The final host rerun passed all 15 failure scenarios after this refinement; independent narrow source review found no remaining issue.
