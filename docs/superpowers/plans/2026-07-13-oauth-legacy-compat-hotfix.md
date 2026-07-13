# OAuth Legacy-Compatibility Hotfix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore current Catbird `main` sign-in against deployed Nest by accepting the legacy `#session_id` callback only during a short-lived, single-use local login attempt.

**Architecture:** Replace the active one-time exchange coordinator with a small `GatewayOAuthLegacyCallback` actor. It returns Petrel's gateway login URL unchanged, records only an in-memory timestamp, strictly consumes and validates the legacy callback, and returns the session ID for the existing `AuthenticationManager` Petrel handoff. The HTTP exchange transport remains removed from active client code; URL-redacted logging and unrelated PR #24 hardening remain intact.

**Tech Stack:** Swift 6, Swift actors, Foundation `URLComponents`, Swift Testing, Xcode iOS Simulator.

## Global Constraints

- Branch from current Catbird `main`; do not modify recovery or security workspaces.
- Accept only `https://catbird.blue/oauth/callback#session_id=...`, treating omitted port and explicit `:443` as equivalent.
- Reject userinfo, query parameters, suffix/lookalike hosts, alternate ports, wrong paths, and any fragment structure other than exactly one `session_id` field.
- Require a live local attempt no older than 60 seconds and consume it before callback validation so malformed callbacks and replays fail locally.
- Session IDs must contain 1 through 512 printable ASCII bytes (`0x21...0x7e`) and must not be logged.
- Return Petrel's login URL byte-for-byte unchanged; do not add `browser_nonce` or `redirect_to`.
- Preserve secret-safe logging and the unrelated Claude review workflow update from PR #24.
- Do not deploy Nest or re-enable `/auth/exchange` in this hotfix.

---

## File Structure

| File | Responsibility |
|---|---|
| `Catbird/Core/Networking/GatewayOAuthExchange.swift` | Replace exchange behavior with the isolated, temporary `GatewayOAuthLegacyCallback` validator and local pending-attempt state. The filename remains stable to avoid unrelated project-file churn. |
| `Catbird/Core/State/AuthManager.swift` | Wire login, add-account, signup, cancellation, and callback handling to the legacy coordinator while preserving the existing Petrel completion path. |
| `CatbirdTests/GatewayOAuthExchangeTests.swift` | Replace exchange-protocol tests with the complete compatibility validation contract. The filename remains stable for focused test selection. |
| `docs/superpowers/specs/2026-07-13-oauth-legacy-compat-hotfix-design.md` | Already records rollout order and the explicit removal gate; verify it remains accurate. |

### Task 1: Strict legacy callback coordinator

**Files:**
- Modify: `CatbirdTests/GatewayOAuthExchangeTests.swift`
- Modify: `Catbird/Core/Networking/GatewayOAuthExchange.swift`

**Interfaces:**
- Produces: `actor GatewayOAuthLegacyCallback`
- Produces: `init(callbackURL: URL, uptime: @escaping @Sendable () -> TimeInterval = ...)`
- Produces: `func prepareLogin(_ loginURL: URL) throws -> URL`
- Produces: `func consume(_ callback: URL) throws -> String`
- Produces: `func cancelPendingLogin()`
- Produces: `enum GatewayOAuthLegacyCallbackError: Error, Equatable { case configuration, flowInProgress, unauthorized }`

- [ ] **Step 1: Replace exchange tests with failing compatibility tests**

Replace the suite with tests that instantiate `GatewayOAuthLegacyCallback`, start an attempt using `prepareLogin`, and assert:

```swift
@Suite("Temporary gateway OAuth legacy callback compatibility")
struct GatewayOAuthExchangeTests {
  private let callbackURL = URL(string: "https://catbird.blue/oauth/callback")!
  private let loginURL = URL(string: "https://api.catbird.blue/auth/login?identifier=alice.test")!

  @Test("login URL remains unchanged and an exact legacy callback succeeds once")
  func validLegacyCallback() async throws {
    let callback = GatewayOAuthLegacyCallback(callbackURL: callbackURL)
    #expect(try await callback.prepareLogin(loginURL) == loginURL)

    let result = try await callback.consume(
      URL(string: "https://catbird.blue/oauth/callback#session_id=session-123")!)
    #expect(result == "session-123")

    await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized) {
      try await callback.consume(
        URL(string: "https://catbird.blue/oauth/callback#session_id=session-123")!)
    }
  }

  @Test("callback requires an active unexpired login attempt")
  func attemptRequiredAndExpiring() async throws {
    let clock = TestUptime()
    let callback = GatewayOAuthLegacyCallback(callbackURL: callbackURL, uptime: { clock.value })
    let validURL = URL(string: "https://catbird.blue/oauth/callback#session_id=session-123")!

    await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized) {
      try await callback.consume(validURL)
    }
    _ = try await callback.prepareLogin(loginURL)
    clock.value = 60.001
    await #expect(throws: GatewayOAuthLegacyCallbackError.unauthorized) {
      try await callback.consume(validURL)
    }
  }
}
```

Add table-driven cases for all required invalid callbacks:

```swift
let invalidURLs = [
  "http://catbird.blue/oauth/callback#session_id=session-123",
  "https://catbird.blue.evil.example/oauth/callback#session_id=session-123",
  "https://catbird.blue@evil.example/oauth/callback#session_id=session-123",
  "https://user@catbird.blue/oauth/callback#session_id=session-123",
  "https://catbird.blue:444/oauth/callback#session_id=session-123",
  "https://catbird.blue/oauth/other#session_id=session-123",
  "https://catbird.blue/oauth/callback?session_id=session-123",
  "https://catbird.blue/oauth/callback?next=%2F#session_id=session-123",
  "https://catbird.blue/oauth/callback#session_id=session-123&extra=value",
  "https://catbird.blue/oauth/callback#extra=value&session_id=session-123",
  "https://catbird.blue/oauth/callback#session_id=",
  "https://catbird.blue/oauth/callback#session_id=session%20id",
]
```

Also construct oversized and non-printable session-ID URLs programmatically, verify omitted and explicit `:443` both pass, verify a malformed callback consumes the pending attempt, verify a live second attempt throws `.flowInProgress`, verify cancellation clears the attempt, and verify a configured callback containing userinfo/query/fragment or a non-HTTPS scheme throws `.configuration` without creating an attempt.

- [ ] **Step 2: Run the focused suite and confirm RED**

Run:

```bash
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  -only-testing:CatbirdTests/GatewayOAuthExchangeTests
```

Expected: compilation fails because `GatewayOAuthLegacyCallback` and `GatewayOAuthLegacyCallbackError` do not yet exist. Preserve the failing output in the task notes.

- [ ] **Step 3: Implement the minimal actor**

Replace the exchange implementation with this structure, keeping helpers private:

```swift
import Foundation

enum GatewayOAuthLegacyCallbackError: Error, Equatable {
  case configuration
  case flowInProgress
  case unauthorized
}

/// Temporary compatibility for Nest's legacy fragment callback.
/// Remove only after the conditions in the hotfix design document are met.
actor GatewayOAuthLegacyCallback {
  static let attemptLifetime: TimeInterval = 60
  static let maximumSessionIDBytes = 512

  private let callbackURL: URL
  private let uptime: @Sendable () -> TimeInterval
  private var pendingCreatedAt: TimeInterval?

  init(
    callbackURL: URL,
    uptime: @escaping @Sendable () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    }
  ) {
    self.callbackURL = callbackURL
    self.uptime = uptime
  }

  func prepareLogin(_ loginURL: URL) throws -> URL {
    if let pendingCreatedAt,
      uptime() - pendingCreatedAt <= Self.attemptLifetime
    {
      throw GatewayOAuthLegacyCallbackError.flowInProgress
    }
    pendingCreatedAt = nil

    guard Self.isValidConfiguredCallback(callbackURL) else {
      throw GatewayOAuthLegacyCallbackError.configuration
    }
    pendingCreatedAt = uptime()
    return loginURL
  }

  func consume(_ callback: URL) throws -> String {
    guard let createdAt = pendingCreatedAt else {
      throw GatewayOAuthLegacyCallbackError.unauthorized
    }
    pendingCreatedAt = nil

    guard uptime() - createdAt <= Self.attemptLifetime,
      let sessionID = Self.validatedSessionID(from: callback, expected: callbackURL)
    else {
      throw GatewayOAuthLegacyCallbackError.unauthorized
    }
    return sessionID
  }

  func cancelPendingLogin() {
    pendingCreatedAt = nil
  }
}
```

`validatedSessionID` must compare lowercased scheme and host, exact effective port and path, reject `user`, `password`, and `query`, require `URLComponents.fragment` to split into exactly one item with name `session_id`, percent-decode its value exactly once, and require 1...512 UTF-8 bytes all within `0x21...0x7e`. `isValidConfiguredCallback` must require HTTPS, host, no userinfo/query/fragment, exact `/oauth/callback`, and effective port 443.

- [ ] **Step 4: Run the focused suite and confirm GREEN**

Run the same focused `xcodebuild test` command.

Expected: `GatewayOAuthExchangeTests` passes with zero failures.

- [ ] **Step 5: Commit the coordinator**

```bash
jj describe -m "Catbird: validate temporary legacy OAuth callbacks"
jj new
```

Expected: the completed commit contains only the coordinator and focused tests.

### Task 2: Wire every authentication path to compatibility mode

**Files:**
- Modify: `Catbird/Core/State/AuthManager.swift`
- Test: `CatbirdTests/GatewayOAuthExchangeTests.swift`

**Interfaces:**
- Consumes: `GatewayOAuthLegacyCallback.prepareLogin(_:)`, `consume(_:)`, and `cancelPendingLogin()` from Task 1.
- Preserves: `AuthenticationManager.handleGatewayCallback(_:)`, `cancelGatewayOAuthFlow()`, `login(handle:)`, `addAccount(handle:)`, and `startSignUp(pdsURL:)` call-site interfaces.

- [ ] **Step 1: Add a source-level wiring regression test**

Add a focused test helper that reads `AuthManager.swift` from `#filePath`, then assert the production source contains `GatewayOAuthLegacyCallback` and `.consume(url)`, while the active manager source contains neither `.redeem(url)` nor `GatewayOAuthExchange(`. This test protects the temporary mode from accidentally posting to `/auth/exchange` before Nest deployment.

```swift
@Test("authentication manager activates only legacy compatibility")
func authenticationManagerWiring() throws {
  let testsURL = URL(fileURLWithPath: #filePath)
  let sourceURL = testsURL.deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Catbird/Core/State/AuthManager.swift")
  let source = try String(contentsOf: sourceURL, encoding: .utf8)

  #expect(source.contains("GatewayOAuthLegacyCallback("))
  #expect(source.contains("gatewayOAuthLegacyCallback.consume(url)"))
  #expect(!source.contains("gatewayOAuthExchange.redeem(url)"))
  #expect(!source.contains("GatewayOAuthExchange("))
}
```

- [ ] **Step 2: Run the focused suite and confirm RED**

Run the Task 1 focused command.

Expected: the new wiring assertions fail because `AuthManager.swift` still references the exchange coordinator.

- [ ] **Step 3: Switch the manager to the legacy coordinator**

In `AuthManager.swift`:

```swift
@ObservationIgnored
private let gatewayOAuthLegacyCallback = GatewayOAuthLegacyCallback(
  callbackURL: URL(string: "https://catbird.blue/oauth/callback")!
)
```

Make `login(handle:)`, `addAccount(handle:)`, and `startSignUp(pdsURL:)` call `gatewayOAuthLegacyCallback.prepareLogin(authURL)`. In `handleGatewayCallback(_:)`, replace network redemption with:

```swift
let sessionID = try await gatewayOAuthLegacyCallback.consume(url)
```

Keep construction of the internal fragment callback and Petrel processing unchanged so the validated session ID is never logged or exposed. Make `cancelGatewayOAuthFlow()` call `gatewayOAuthLegacyCallback.cancelPendingLogin()`.

Do not change the existing redacted logging in `AuthManager`, `LoginView`, `AccountSwitcherView`, `CatbirdApp`, or `URLHandler`.

- [ ] **Step 4: Run focused tests and build**

Run:

```bash
xcodebuild test -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80' \
  -only-testing:CatbirdTests/GatewayOAuthExchangeTests
xcodebuild build -project Catbird.xcodeproj -scheme Catbird \
  -destination 'platform=iOS Simulator,id=40111BBE-8709-40D0-9016-A27448486A80'
```

Expected: focused tests pass and `** BUILD SUCCEEDED **` appears.

- [ ] **Step 5: Audit for secret logging and active exchange paths**

Run:

```bash
rg -n "absoluteString|session_id|browser_nonce|auth/exchange|gatewayOAuthExchange" \
  Catbird/App/CatbirdApp.swift \
  Catbird/Core/Networking/URLHandler.swift \
  Catbird/Core/Networking/GatewayOAuthExchange.swift \
  Catbird/Core/State/AuthManager.swift \
  Catbird/Features/Auth/Views/LoginView.swift \
  Catbird/Features/Auth/Views/AccountSwitcherView.swift
```

Expected: `session_id` appears only in validation and the in-memory Petrel callback construction; no callback/session value is interpolated into logging; `browser_nonce`, `/auth/exchange`, and `gatewayOAuthExchange` have no active production matches.

- [ ] **Step 6: Commit the wiring**

```bash
jj describe -m "Catbird: activate legacy OAuth compatibility"
jj new
```

Expected: the completed commit contains manager wiring and its regression test only.

### Task 3: Verify rollout safety and runtime sign-in

**Files:**
- Verify: `docs/superpowers/specs/2026-07-13-oauth-legacy-compat-hotfix-design.md`
- Verify: all files changed in Tasks 1 and 2

**Interfaces:**
- Consumes: the fully wired compatibility flow from Tasks 1 and 2.
- Produces: evidence that the hotfix is buildable, tested, narrowly scoped, and works against deployed Nest.

- [ ] **Step 1: Verify the documented removal gate**

Confirm the design document explicitly requires: deploy Nest with dual legacy/exchange support; verify `POST /auth/exchange`; retain legacy support for supported client lifetimes; observe `catbird_oauth_exchanges_total{outcome="legacy_callback"}`; only then remove this compatibility path.

Expected: no documentation edit is necessary. If wording drifted, update only that design document and describe the exact correction in the commit.

- [ ] **Step 2: Run the final automated verification**

Run the focused test and iOS build commands from Task 2, then:

```bash
jj diff --summary -r 'main..@'
jj diff --stat -r 'main..@'
rg -n "PLACEHOLDER_MARKER|DEFERRED_IMPLEMENTATION_MARKER" \
  Catbird/Core/Networking/GatewayOAuthExchange.swift \
  Catbird/Core/State/AuthManager.swift \
  CatbirdTests/GatewayOAuthExchangeTests.swift
```

Expected: only the planned client/test/docs files differ from `main`; tests and build pass; deferred-work marker scan is empty.

- [ ] **Step 3: Run simulator authentication against deployed Nest**

Install and launch the built hotfix on simulator `40111BBE-8709-40D0-9016-A27448486A80`. Start login, complete the currently deployed Nest browser flow, and confirm the callback reaches the authenticated app instead of producing exchange error 2.

Expected: authenticated Catbird UI appears and no request to `/auth/exchange` occurs. Do not capture or paste callback URLs, session IDs, cookies, or credentials into logs or notes.

- [ ] **Step 4: Commit any verification-only documentation correction**

If Step 1 required a docs correction:

```bash
jj describe -m "Catbird: document OAuth compatibility removal gate"
jj new
```

Otherwise, leave the working copy empty and create no extra commit.

- [ ] **Step 5: Prepare integration handoff**

Record the exact passing test/build commands and runtime result. Do not merge automatically. The next authorized sequence is: merge this hotfix to `main`; rebase recovery; rebase the Catbird security/lifecycle branch; rerun focused OAuth tests on both descendant lines.
