App Review Notes – Catbird

Overview
- Catbird is an independent, third‑party client for the Bluesky social network (AT Protocol). It is not affiliated with Bluesky PBLLC.
- Primary features: browse posts, compose, manage lists, and optional push notifications for mentions/replies.

Demo Account for Review
- Username: <provide>
- Password: <provide>
- Notes: Account is pre‑populated with follows and sample activity so notifications and feeds are non‑empty.

Push Notifications
- Purpose: Delivers user‑requested social updates (mentions, replies, etc.). No advertising or marketing pushes.
- To test: Log in with the demo account above. From another Bluesky account, mention the demo account to trigger a push. Alternatively, we can trigger a test notification on request.
- Data handling: The app registers an APNs device token and can send it to our notification service if the user enables notifications. Logging out unregisters the device.

Privacy & Data Use
- Data collected: User identifier (Bluesky DID/handle), device push token, user’s mute/block lists (for notification filtering), and diagnostics (crash and performance data) via Sentry.
- Use: App functionality (routing notifications and filtering mutes/blocks) and diagnostics (improving stability). No tracking across apps.
- Retention: Only while notifications are active for the user. On logout or opt‑out, token is unregistered and related data is deleted. Diagnostics are retained per Sentry retention policy.
- Deletion: Users can log out to stop collection and may request deletion via the support contact.

Moderation & Safety
- Content labels and sensitive content are respected per Bluesky settings; sensitive posts are hidden or warned by default.
- Users can report posts/users via the Report UI; reports route to the Bluesky moderation system.
- Users can mute or block accounts; the app respects these for display and notification filtering.

Permissions
- Notifications: Requested via standard iOS prompt; app remains functional if declined.
- Photos: Media attachments use the system photo picker (no Photo Library permission required). Camera access is not requested.

Legal & Support
- Privacy Policy: <https://YOUR-DOMAIN/privacy>
- Terms of Service: <https://YOUR-DOMAIN/terms>
- Support: <https://YOUR-DOMAIN/support> or mailto:<support@YOUR-DOMAIN>
