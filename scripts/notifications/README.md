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

## Notification list policy, cache and pagination

The separate policy harness preserves the first harness and its receipts:

```sh
python3 scripts/notifications/prepare_policy_tests.py --output scripts/notifications/_harness-policy
```

It adds the current `NotificationListVisibilityPolicy.swift`, the actual twelve `NotificationListVisibilityPolicyTests.swift` tests, and fifteen exact spans from `NotificationsViewModel.swift`. The only edits to the policy and its app test file are import substitutions for the generated test module. The manifest records and verifies equal hashes of the original and generated test bodies after removing imports.

The additional view-model tests exercise the real computed projection, raw group cache, load/fetch/refresh methods, grouping, and via-repost subject helper. They check Observation invalidation after live preference changes and rollback, restoration of hidden cached rows without refetch, raw cursor progression through fully filtered pages, bounded automatic filling, repeated-cursor termination, replacing the old cursor chain on refresh, and grouping via-repost events by their original post rather than a shared repost reference.

This package retains the original eighteen preference tests. The generated fake DTO/API surface is extended locally for notification rows and list requests; the original fake file and first-harness outputs stay unchanged. Only external post hydration and follow-record lookup are inert in the extracted view model. SwiftUI rendering, real Petrel decoding, navigation, device notification delivery, and MLS behavior still require their respective app and integration checks.
