# Support tip completion: causal fixture and paired source handoff

A support-tip purchase could return while the app listener was still finishing the same transaction. A controlled fixture reproduced that behavior against the unchanged r10 service, then passed with the minimal completion-joining change. The service now lets every delivery of an in-flight transaction await one store-owned finish task and its resulting message. The strict local StoreKit test also retains immediate result assertions while adding phase receipts and fail-closed transaction-settlement gates. Fresh app-host tests and the strict simulator lifecycle remain the next qualification step; this source packet does not explain all five archived r10 runtime issues.

Governing plan: [live-feedback parallel execution](/Users/joshlacalamito/Developer/Catbird+Petrel/docs/execution-plans/2026-10-02-live-feedback-parallel-execution.md). This is a narrow bug fix and test-evidence update, with no new provisional API or schema decision.

## Exact source custody

| Variant | Governing base | Initial completion source | Final source tip |
|---|---|---|---|
| Lite | `33a10c24759f85cf14ae97fce686347f84e66a62` | `97e06a40e95b68453382aa4f7c0805c9fe61a4f7` | `0a182a83f1e0fa88a760a5e1dbf0e73029ec0e09` |
| Full | `d4a1535c801216d9f328ab3b3fe8b85e51d30a91` | `408640430a153a2f25f90c70321ff6d77ee4537a` | `5d49d72cec0d1221d4a97726abc01cb813c31892` |

The final tip includes the initial source change. The final commit alone contains the last immediate-oracle correction, so integration must use the complete range from the listed base or both commits. Each source unit was followed immediately by `jj new`. The aggregate diff changes exactly the three Swift files below. Their contents are byte-identical between Lite and Full; no Lite ancestry was merged into Full, and no app hook, settings route, catalog, scheme, project, runner, frozen r10 input, or built product was edited.

| Source file | Final SHA-256 |
|---|---|
| [Catbird/Features/Settings/Services/SupportTipStore.swift](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/settings-storekit-completion-lite/Catbird/Features/Settings/Services/SupportTipStore.swift) | `4da68b0c9fd6d6998db5ca10577b60b59ebe5d312abeefbf501d4a2ea08457f9` |
| [CatbirdTests/SupportTipStoreTests.swift](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/settings-storekit-completion-lite/CatbirdTests/SupportTipStoreTests.swift) | `5b3e44286356fa191df40013cebe62bc90cdfffe3d5d6a82205ca62ce42f2d0b` |
| [CatbirdTests/SupportTipStoreKitTests.swift](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/settings-storekit-completion-lite/CatbirdTests/SupportTipStoreKitTests.swift) | `ea39bffdaa9fee3756741eb46a0827a0f5e0f88cac58879e7518fb6f5579e364` |

## Causal proof

The original handler inserts a verified allowed consumable transaction ID into its handled set, then awaits `finish()`. A duplicate delivery sees the ID and returns immediately; it does not await the unfinished operation or the subsequent purchase message. The new parameterized test supplies a verified transaction whose `finish()` is held by an explicit continuation latch. The app update observer enters that latch first. A purchase then returns the same transaction, and the test observes whether the purchase has returned and whether the purchase state has cleared before the latch is released.

The fixture purchase method is MainActor-isolated and has no suspension between incrementing its call count and returning the transaction. The test can therefore observe that count after the purchase path has reached its completion wait or returned. No timer releases the finish latch. The two cases leave the waiting purchase uncancelled or cancel it while finish remains blocked. Against the original service, both cases return early, clear purchasing state early, and return before thanks is published: six failed expectations, exit 1. With the completion task, all twelve methods pass, including the two new cases: thirteen invocations, exit 0.

The cancelled variant checks immediately after cancellation, then yields while reading `finishGate.completedIDs` and releases the latch without a further post-yield waiting assertion. The fixture therefore does not independently isolate sustained cancellation waiting through that yield. That property is supported by the source semantics of awaiting the unstructured completion task through `Task.value`; it must not be described as a stronger cancellation experiment than was performed.

The implementation publishes one task under the transaction ID before suspending. That task awaits finish, inserts the completed ID, removes the in-flight entry, and publishes the existing message without another suspension. All duplicate callers await its value. Cancelling a waiting caller does not cancel the store-owned task. Both the old and new service retain the existing unbounded handled-transaction-ID set; neither has a 100-entry bound. Verified-product allowlisting, consumable checking, unverified handling, catalog ownership, observer startup, cancellation wording, and pending wording remain unchanged.

Permanent fixture artifacts are retained under [/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-harness](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-harness). They contain the exact original service and the exact same final mock test used on both sides of the comparison:

| Artifact | SHA-256 |
|---|---|
| [Package.swift](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-harness/Package.swift) | `020c509f3cd5c4d7b5caafe582f8e670902d399c5dc50b6f7ea6ac65c10c4d08` |
| [source-before/SupportTipStore.swift](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-harness/source-before/SupportTipStore.swift) | `21438d0faf1772d04bdabdd6e18c33485e74ef9a7a0f18ad8e0f92e257cfab1c` |
| [source-after/SupportTipStore.swift](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-harness/source-after/SupportTipStore.swift) | `4da68b0c9fd6d6998db5ca10577b60b59ebe5d312abeefbf501d4a2ea08457f9` |
| [Tests/CatbirdTests/SupportTipStoreTests.swift](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-harness/Tests/CatbirdTests/SupportTipStoreTests.swift) | `5b3e44286356fa191df40013cebe62bc90cdfffe3d5d6a82205ca62ce42f2d0b` |
| [before-fix-final.log](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-harness/before-fix-final.log) | `9dacea5cc2fc5954dbd16fbbaa9fe739eb669cefa9a3726425af987311ce1d70` |
| [after-fix-final.log](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-harness/after-fix-final.log) | `424f524142f72785337fda4afd2c6e8f43041bf0006c746eb177c6f3e7b86aaa` |
| [causal-custody.json](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-harness/causal-custody.json) | `6752ef481cc02eb023157a30c33ad64dd0268c4aaedafe1d5631ada6ee9a5753` |

The retained custody file records return codes 1 and 0, and the raw logs record the corresponding failures and passing test outcomes. No standalone command receipt, compiler/executable identity receipt, child PID, process-group inspection, or explicit reap receipt was preserved. Those process facts cannot be inferred retrospectively from a green log or the source packet. The private harness is a Swift 6 macOS package using the real service source and an injected mock client; it is separate from an iOS app-host or real StoreKit run.

## Strict local StoreKit successor

- Both required launch flags remain fatal gates. The first override setup suppresses transaction observation until its public error setter and exact error readback pass. Its successful after receipt then collects actual state. The initial injected product-load failure and subsequent loaded state remain throwing requirements.
- The independent four-ID catalog, exact decimal prices, unfiltered StoreKit count/IDs, consumable types, and prices remain throwing prerequisites before any purchase. Every purchase additionally requires loaded, not-loading, not-purchasing, and the exact chosen product still present.
- All seven direct purchase attempts now assert the original nil/literal result immediately after `await store.purchase`, before any diagnostic await: first tip, repeated tip, cancellation (nil), generic error, unavailable product, pending approval, and final repeated tip. Each also immediately requires purchasing state to be cleared. Original later cancellation/error/pending literal checks remain. The three direct success paths cannot pass merely because thanks appears during the later wait.
- The separate completion gate polls actual unfinished IDs and message state with a ten-second polling deadline and throws on failure. Compared with r10’s immediate unfinished-ID sample at line 87, the successor allows a bounded 10-second completion drain before requiring emptiness; all seven message/state assertions remain immediate, while observer approval legitimately waits for the asynchronous update. It runs after each success, including the first and second tip individually and the approved pending tip. Override and Ask to Buy changes require no unfinished verified tips first. The approval observer may legitimately complete asynchronously; that branch retains a bounded wait for thanks.
- Every action emits structured before/after/throw receipts; override readbacks and completion gates emit their own receipts. Fields include phase, observable result/message, catalog state, purchase state, unfinished verified tip IDs, and session transaction IDs/original IDs/product IDs/states/pending and issue flags. Gate assertions use the unfinished-ID sample printed in the final gate receipt. StoreKit and session observations are sequential, not an atomic cross-system snapshot.
- Polling pauses only while its stated live condition remains unmet. Helpers never finish a transaction or clear session history. Initial session setup and final deferred cleanup retain their original transaction clearing.

## Validation and remaining gate

- Exact final service: Swift 6 iOS simulator module emission passed; [command/output](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-typecheck/module.log). Exact final mock tests: Swift 6 iOS macro typecheck passed; [command/output](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-typecheck/unit-test-typecheck.log). Both are unchanged since those checks.
- The strict runtime test passed Swift 6 iOS typecheck before the final receipt and immediate-oracle refinements, at file SHA-256 `df7f089fceec00355e211332cee102772b50b48510b62581e48bdd0b17f8a402`; [log](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-typecheck/runtime-test-typecheck.log). The final file was parsed and linted after those refinements: [parse output](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-typecheck/runtime-test-final-parse.log), [lint output](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-typecheck/runtime-test-final-lint.log). Both commands returned exit 0. Final lint reports two length warnings (test function 113 lines; suite body 258 lines). Final strict-file typechecking and app compilation remain for the parent build; no later compiler or runtime execution was performed in this lane.
- Service/mock scoped SwiftLint exited 0 without diagnostics: [log](/Users/joshlacalamito/Developer/.workspaces/catbird-live-feedback-20261002/artifacts/storekit-completion-typecheck/service-unit-swiftlint.log).
- Independent source reviews verified the MainActor latch ordering, cancellation behavior, one finish per ID, preserved service guards, and insertion-only preservation of all eleven baseline mock methods. A separate strict-test review checked retained catalog and lifecycle oracles; its timing findings were addressed by the immediate assertions above.
- Required next run: build fresh app-host products from the final source, execute the exact twelve-method/thirteen-invocation mock suite in the app host, then execute the strict local StoreKit lifecycle with both required launch flags and retain its phase receipts. The parent owns product custody, runtime grants, process evidence, and the independent landscape UI gate. A green private harness or typecheck does not qualify those runtime gates.

Exact mock-suite inventory:

| Method in `SupportTipStoreTests` | Invocations |
|---|---:|
| `unavailableAndFailedCatalogCanBeRetried()` | 1 |
| `onlyApprovedTipsAppearInAscendingPriceOrder()` | 1 |
| `successfulTipFinishesAndAllowsAnotherIntentionalTip()` | 1 |
| `cancellationAndFailureLeavePurchaseAvailableForRetry()` | 1 |
| `pendingTipCompletesFromUpdatesWithoutAboutScreen()` | 1 |
| `appLaunchReconcilesUnfinishedTipsAndStartsOnlyOnce()` | 1 |
| `duplicatePurchaseAndUpdateAreFinishedOnce()` | 1 |
| `unverifiedAndUnrelatedTransactionsAreNotFinished()` | 1 |
| `storefrontChangeRefreshesLocalizedCatalog()` | 1 |
| `unknownOrStaleProductCannotStartPurchase()` | 1 |
| `cancelledViewLoadDoesNotAbandonReopenedView()` | 1 |
| `duplicatePurchaseWaitsForTheObserversInFlightFinish(cancelPurchaser: Bool)`; arguments `[false, true]` | 2 |
