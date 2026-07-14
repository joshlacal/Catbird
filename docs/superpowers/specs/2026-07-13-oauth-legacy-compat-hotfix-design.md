# OAuth Legacy-Compatibility Hotfix Design

Date: 2026-07-13

## Context

Current Catbird `main` requires the one-time gateway exchange endpoint introduced by PR #24. The deployed Nest at `https://api.catbird.blue` still serves the legacy callback flow and returns HTTP 404 for `POST /auth/exchange`. Catbird converts that non-success response into `GatewayOAuthExchangeError.unauthorized`, so current `main` cannot complete sign-in.

This is a staged-rollout failure: the new client shipped before the compatible server deployment. The hotfix restores compatibility with deployed Nest while retaining the security hardening that is independent of the exchange protocol.

## Decision

Create a dedicated hotfix from current Catbird `main`. Restore only the legacy gateway callback behavior required by deployed Nest. Do not revert PR #24 wholesale.

The compatibility flow is:

1. Catbird starts a local login attempt and records a short-lived, single-use proof that a callback is expected.
2. Catbird opens the unmodified gateway login URL produced by Petrel. It does not attach `browser_nonce` or `redirect_to` while compatibility mode is active.
3. Catbird accepts only the exact callback origin `https://catbird.blue:443` and exact path `/oauth/callback`, with no userinfo or query.
4. Catbird requires exactly one fragment field named `session_id`, validates it as an exact canonical lowercase hyphenated UUID, consumes the active login attempt before processing, and passes the validated callback to Petrel.
5. Missing, expired, replayed, malformed, or unexpected callbacks fail closed without logging secrets.

## Preserved Hardening

The hotfix must preserve:

- exact scheme, host, effective port, and path validation;
- rejection of userinfo, query parameters, suffix-host tricks, alternate ports, and extra fragment fields;
- bounded callback parsing and canonical UUID session-ID validation;
- single-use, expiring local login-attempt state;
- redirect refusal and ephemeral transport behavior retained by unaffected code;
- secret-safe logging that never emits callback URLs, session IDs, exchange codes, nonces, or credentials;
- the unrelated Claude review workflow update from PR #24.

The hotfix may leave the exchange implementation available as dormant code only if production paths cannot reach it. Tests and names must make the active compatibility mode unambiguous. Deleting dormant exchange code is optional and must not enlarge the behavioral rollback.

## Test Contract

Tests must be written before the compatibility implementation and must demonstrate failure on current `main`.

Required positive case:

- an active, unexpired login attempt accepts an exact `https://catbird.blue/oauth/callback#session_id=...` callback once.

Required rejection cases:

- callback without an active login attempt;
- replay after the attempt was consumed;
- expired login attempt;
- `session_id` supplied in the query;
- suffix or lookalike hosts;
- URL userinfo;
- non-default or explicitly disallowed ports;
- wrong path;
- multiple fragment fields or extra fragment data;
- missing, empty, oversized, noncanonical, uppercase, malformed, or structurally significant (`&`, `%`, `=`) session IDs.

Deployed Nest creates legacy session IDs with Rust `Uuid::new_v4().to_string()`, which emits the canonical lowercase hyphenated UUID form. Catbird intentionally narrows acceptance to that deployed format. Because this alphabet cannot contain fragment delimiters or percent escapes, the validated value can be handed to Petrel unchanged; Petrel does not need a parser change in this hotfix.

Focused tests must pass on the pinned iOS simulator, followed by an iOS build. Runtime verification must confirm a real simulator login reaches the authenticated app against currently deployed Nest.

## Server Compatibility Before Exchange Deployment

Nest must be deployed before Catbird re-enables the one-time exchange client. The server deployment must support old and new clients simultaneously:

- requests without `browser_nonce` follow the legacy `session_id` callback path;
- requests with `browser_nonce` produce a one-time code and support `POST /auth/exchange`;
- `OAUTH_LEGACY_CALLBACK_UNTIL` is declared in configuration and deployment documentation, set explicitly in production, validated at startup, and chosen beyond the supported lifetime of legacy Catbird versions;
- changing the deadline requires a controlled restart because the current implementation caches it;
- router-level integration tests exercise legacy and exchange flows together;
- Redis-backed single-use, nonce/origin binding, expiry, and legacy in-flight migration tests run against a real test Redis;
- production smoke tests verify both modes before any new Catbird exchange client is released.

Legacy support must not be disabled merely because the new client exists. Removal is gated on supported-version policy and observed legacy usage, including `catbird_oauth_exchanges_total{outcome="legacy_callback"}`.

## Delivery Sequence

1. Land and merge this Catbird compatibility hotfix into `main`.
2. Rebase the lost-work recovery stack onto the new `main` and rerun its OAuth tests.
3. Rebase the Catbird security/lifecycle branch onto the same `main` and rerun its OAuth tests.
4. Add the missing Nest configuration/documentation and dual-mode integration coverage.
5. Deploy Nest first with legacy compatibility explicitly enabled and verify both modes.
6. Reintroduce the exchange-code Catbird client in a separate reviewed change.
7. Remove the temporary compatibility path only after the Nest endpoint is deployed and verified, supported legacy clients have aged out, and telemetry shows the legacy path can be safely disabled.

## Non-Goals

- Deploying Nest as part of this Catbird hotfix.
- Reverting unrelated CI, privacy logging, URL redaction, or authentication hardening.
- Merging unfinished recovery UI work into the hotfix.
- Moving or rewriting concurrent security workspaces.
