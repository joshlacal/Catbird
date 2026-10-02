# Notification preference regression harness

This small Swift package tests the production `NotificationManager` preference and push-registration methods against controlled responses. The runner extracts complete source declarations, unchanged, from the current checkout and records their hashes in `extraction-manifest.json`. SwiftPM runs with two build jobs and Swift 5 language mode, matching the app project's `SWIFT_VERSION` setting.

```sh
python3 scripts/notifications/prepare_and_test.py --output scripts/notifications/_harness
```

The runner writes `test.log` and `test-result.json`, including the source hash and whether the source changed while the tests ran. To inspect the generated package before running it:

```sh
python3 scripts/notifications/prepare_and_test.py --prepare-only --output scripts/notifications/_harness
swift test --package-path scripts/notifications/_harness --jobs 2
```

The tests hold network and identity lookup responses at explicit gates. They cover persisted master-disable registration gating, chat preference and defaults synchronization, failed-write rollback, serialized successful and failed writes, account changes during pending work, queued chat changes, stale reads during optimistic writes, cancellation before dispatch and after response, and compensating unregistration when disabling push races registration.

`TestDoubles.swift` substitutes the Petrel request/response types, fake network client, in-memory defaults, and app state. `ManagerTestSeams.swift` supplies setup and inspection methods and makes unrelated platform, relationship-sync, cleanup, and MLS side effects inert. The extraction does not add actor isolation to the production class. The Full checkout's MLS-specific fields remain present; its MLS effects are stubbed.

No test accesses a live account, network service, device, APNS, Keychain, or real defaults suite. Passing establishes behavior of the extracted production methods under controlled interleavings. It does not establish a full Xcode/Petrel build, actual notification delivery, UI behavior, or MLS registration behavior.

To verify that these tests detect the original failure modes, use an output directory outside the checkout:

```sh
python3 scripts/notifications/negative_controls.py --output /tmp/catbird-notification-negative-controls
```

This copies only the production source into two external fixtures, records the deliberate mutations, and requires the selected tests to fail with assertions after a successful build. One control removes master-setting guards; the other removes snapshot and rollback mirror synchronization. `results.json` records whether both controls were detected. Production sources are never modified.
