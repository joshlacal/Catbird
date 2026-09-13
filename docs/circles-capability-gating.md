# Account-specific Circles availability

Circles entry points require the active account's PDS to answer an authenticated, read-only `com.atproto.space.listSpaces?type=blue.catbird.circle&limit=1` query with HTTP 200 and a decoded response, and the shared Circle AppView to advertise `enabled`. An empty Spaces list is valid. The probe creates no space, repository, membership, or post.

## Detection decision

Chose a PDS read probe provisionally because the current `com.atproto.server.describeServer` lexicon has no Spaces capability field. The optional DID `#atproto_space_host` service routes authority requests and is not a support flag: the proposal explicitly allows falling back to `#atproto_pds`. Rejected a global AppView-only gate because it says nothing about the user's PDS. This choice is reversible before merge by replacing `GatewayCircleTransport.capabilities`; explicit protocol capability metadata should replace the probe if standardized.

Sources: [Spaces proposal](https://github.com/bluesky-social/proposals/blob/main/0016-permissioned-data/README.md), [XRPC specification](https://atproto.com/specs/xrpc), local Petrel `generator/lexicons/com/atproto/space/listSpaces.json`, and Swan `Sources/SwanHTTP/SwanHTTP.swift` / `SwanSpaceListXRPC.swift`.

Only structured HTTP 501 `MethodNotImplemented` and Swan HTTP 404 `permissioned_endpoint_unavailable` mean unsupported. Authentication/authorization errors, generic 404, HTTP 429, temporary server failure (including Swan `permissioned_data_pending`), transport failure, and malformed success responses remain unknown. Unknown hides entry points without asserting permanent server incompatibility. Foreground entry retries discovery.

## State and UI

`AppState.circleCapability` is observable and starts unknown. `circlesEnabled` is true only for supported. No process-global cached support or user-default override remains. Client replacement and account refresh clear the state. In-flight results are accepted only for the same active AppState instance, client, account DID, PDS URL, and latest probe ID; cancelled probes cannot enable the feature.

Feed discovery, composer choices, Circle navigation routes, and the notifications compatibility accessor consume this state. Notifications loading changes belong to a separate task. A private draft keeps its audience visible if availability changes, blocks submission, and never silently becomes public. Existing debug fixture installation writes only the fixture account's state.

## Validation boundaries

Tests cover enabled/disabled capability responses, explicit unsupported vs unknown failures, cancellation, and a delayed result after a different-account or same-DID session replacement. Error classification tests require the exact status/code pairs. These fixtures do not establish connectivity to a real supported PDS or successful Circles writes. A full runtime check requires supported and unsupported signed-in accounts: verify feed, composer, notifications, navigation, foreground retry, and repeated account switches. Build/test results are recorded in the task handoff.

## First-time consent limitation

Swan requires the requested Space type to be covered by the token's grant. Filtering to `blue.catbird.circle` is required: an unfiltered listing requests wildcard access and rejects Catbird's type-limited permission. Nest initial login scopes do not include Circle Spaces permission; existing `ensureGatewayPermission(.circleSpaces)` entry points live inside Circles. A fresh supported account remains unknown until consent is granted through the deliberate Enable Circles action in Account settings. HTTP 401 cannot safely prove support because Swan deliberately uses the same response for invalid authentication, missing scope, and inactive accounts. The user authorized this separate settings consent action; initial login permissions remain unchanged. A successful upgrade is followed by the same filtered PDS/AppView probe. Cancellation stays retryable and results are bound to the originating account session. No eligibility banner is shown: the protocol has no reliable pre-consent discovery signal, and an unknown authentication failure must not be advertised as available support.
