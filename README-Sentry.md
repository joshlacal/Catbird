Sentry Integration

Overview

- Catbird can send crashes, performance traces, and breadcrumbs to Sentry.
- Petrel logs are bridged into Sentry as breadcrumbs (debug/info) and events (error) without adding Sentry to Petrel.

Setup (Xcode)

- In Xcode, add package: https://github.com/getsentry/sentry-cocoa (latest 8.x).
- Link the `Sentry` product to the Catbird app target only (not Petrel).

Configuration

- Provide a DSN via either:
  - Info.plist: add string key `SENTRY_DSN` with your DSN value, or
  - Env var: `SENTRY_DSN=...` in the scheme’s Environment.

What’s in code

- `SentryService.start()` initializes Sentry if the SDK is present.
- `PetrelSentryBridge.enable()` subscribes to Petrel log events and forwards them:
  - debug/info → Sentry breadcrumbs
  - error → Sentry breadcrumb + captured message event
- Both are called at app startup in `CatbirdApp.init()`.

Notes

- The Sentry code is guarded by `#if canImport(Sentry)` so builds work even if the SDK isn’t added yet.
- No Sentry dependency was added to Petrel; only a public observer API.

