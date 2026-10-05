import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import Catbird

#if DEBUG && os(iOS) && targetEnvironment(simulator)
/// Run on the dedicated local simulator. SKTestSession never changes the App Store Connect catalog.
@MainActor
@Suite(.serialized)
struct SupportTipStoreKitTests {
  @Test(.timeLimit(.minutes(1)))
  func localCatalogAndPurchaseLifecycle() async throws {
    try #require(
      ProcessInfo.processInfo.arguments.contains("--support-tip-storekit-test"),
      "Launch with --support-tip-storekit-test to configure local StoreKit before starting its listener."
    )
    try #require(
      ProcessInfo.processInfo.arguments.contains("--scene-runtime-ui-fixture"),
      "Use the offline scene fixture so About cannot load products before the local session is ready."
    )
    let session = try SKTestSession(configurationFileNamed: "SupportCatbird")
    session.resetToDefaultState()
    session.clearTransactions()
    session.disableDialogs = true
    session.locale = Locale(identifier: "en_US")
    session.storefront = "USA"
    defer {
      session.resetToDefaultState()
      session.clearTransactions()
    }

    // The dedicated launch flag defers only startup; keep the same app-owned singleton and listener.
    let store = SupportTipStore.shared

    // Verify that the local session intercepts StoreKit before exercising any purchase.
    try await configureInterception(store: store, session: session)
    try await recordAction("catalog.interception.load", store: store, session: session) {
      store.start()
      await store.loadProducts(forceReload: true)
    }
    try #require(store.loadState == .failed)
    try await setError(nil, forAPI: .loadProducts, phase: "catalog.clearOverride", store: store, session: session)
    try await recordAction("catalog.load", store: store, session: session) {
      await store.loadProducts(forceReload: true)
    }
    try #require(store.loadState == .loaded)

    // Independent catalog expectations must pass before any simulated purchase is allowed.
    let expectedIDs: Set<String> = [
      "blue.catbird.support.onetime.small",
      "blue.catbird.support.onetime.medium",
      "blue.catbird.support.onetime.large",
      "blue.catbird.support.onetime.extralarge"
    ]
    let expectedPricesByID: [String: Decimal] = [
      "blue.catbird.support.onetime.small": Decimal(string: "4.99")!,
      "blue.catbird.support.onetime.medium": Decimal(string: "9.99")!,
      "blue.catbird.support.onetime.large": Decimal(string: "19.99")!,
      "blue.catbird.support.onetime.extralarge": Decimal(string: "49.99")!
    ]
    let displayedProducts = store.products
    let displayedCountMatches = displayedProducts.count == expectedIDs.count
    let displayedIDsMatch = Set(displayedProducts.map(\.id)) == expectedIDs
    try #require(displayedCountMatches)
    try #require(displayedIDsMatch)
    let displayedPricesByID = Dictionary(uniqueKeysWithValues: displayedProducts.map { ($0.id, $0.price) })
    let displayedPricesMatch = displayedPricesByID == expectedPricesByID
    try #require(displayedPricesMatch)

    // Inspect StoreKit's unfiltered products; the app adapter hides non-consumable types.
    var rawProducts: [Product] = []
    try await recordAction("catalog.rawProducts", store: store, session: session) {
      rawProducts = try await Product.products(for: expectedIDs)
    }
    let rawCountMatches = rawProducts.count == expectedIDs.count
    let rawIDsMatch = Set(rawProducts.map(\.id)) == expectedIDs
    let rawTypesMatch = rawProducts.allSatisfy { $0.type == .consumable }
    try #require(rawCountMatches)
    try #require(rawIDsMatch)
    try #require(rawTypesMatch)
    let rawPricesByID = Dictionary(uniqueKeysWithValues: rawProducts.map { ($0.id, $0.price) })
    let rawPricesMatch = rawPricesByID == expectedPricesByID
    try #require(rawPricesMatch)
    let tip = try #require(store.products.first)

    try await purchase(
      tip, phase: "purchase.first", expectedImmediateMessage: "Thanks for your support!", store: store, session: session
    )
    try await requireSuccess(phase: "purchase.first", store: store, session: session)
    try await purchase(
      tip, phase: "purchase.repeat", expectedImmediateMessage: "Thanks for your support!", store: store, session: session
    )
    try await requireSuccess(phase: "purchase.repeat", store: store, session: session)
    let completed = session.allTransactions().filter { $0.productIdentifier == tip.id && $0.state == .purchased }
    try #require(completed.count == 2)
    let distinctCompletedCount = Set(completed.map(\.identifier)).count
    try #require(distinctCompletedCount == 2)
    // Both purchases were finished and acknowledged once, so neither can return as a new tip.
    let completedAcknowledged = completed.allSatisfy { store.handledTransactionIDs.contains(UInt64($0.identifier)) }
    try #require(completedAcknowledged)

    try await setError(.generic(.userCancelled), forAPI: .purchase, phase: "cancel.override", store: store, session: session)
    try await purchase(
      tip, phase: "cancel.purchase", requiresImmediateMessage: true, store: store, session: session
    )
    try #require(store.purchaseMessage == nil)
    try #require(!store.isPurchasing)
    try await setError(.generic(.unknown), forAPI: .purchase, phase: "genericError.override", store: store, session: session)
    try await purchase(
      tip, phase: "genericError.purchase", expectedImmediateMessage: "Your tip couldn’t be completed. Please try again.",
      store: store, session: session
    )
    try #require(store.purchaseMessage == "Your tip couldn’t be completed. Please try again.")
    try await setError(.purchase(.productUnavailable), forAPI: .purchase, phase: "unavailable.override", store: store, session: session)
    try await purchase(
      tip, phase: "unavailable.purchase", expectedImmediateMessage: "Your tip couldn’t be completed. Please try again.",
      store: store, session: session
    )
    try #require(store.purchaseMessage == "Your tip couldn’t be completed. Please try again.")
    try await setError(nil, forAPI: .purchase, phase: "purchase.clearOverride", store: store, session: session)

    // No About view is mounted: approval must reach the application-owned observer.
    try await setAskToBuy(true, phase: "pending.enable", store: store, session: session)
    try await purchase(
      tip, phase: "pending.purchase", expectedImmediateMessage: "Your tip is pending approval. Thanks for your support!",
      store: store, session: session
    )
    try #require(store.purchaseMessage == "Your tip is pending approval. Thanks for your support!")
    let pending = try #require(session.allTransactions().first {
      $0.productIdentifier == tip.id && $0.pendingAskToBuyConfirmation
    })
    try await recordAction("pending.approve", store: store, session: session) {
      try session.approveAskToBuyTransaction(identifier: pending.identifier)
    }
    try await requireSuccess(phase: "pending.approve", store: store, session: session)

    // Clearing an error or completing an approval never permanently disables repeated tips.
    try await setAskToBuy(false, phase: "pending.disable", store: store, session: session)
    try await purchase(
      tip, phase: "purchase.afterApproval", expectedImmediateMessage: "Thanks for your support!", store: store, session: session
    )
    try await requireSuccess(phase: "purchase.afterApproval", store: store, session: session)
  }

  private func setAskToBuy(_ enabled: Bool, phase: String, store: SupportTipStore, session: SKTestSession) async throws {
    try await recordAction(phase, store: store, session: session) {
      try await requireNoUnfinished(phase: phase, store: store, session: session)
      session.askToBuyEnabled = enabled
      let readbackMatches = session.askToBuyEnabled == enabled
      try #require(readbackMatches, "\(phase): Ask to Buy readback must match the requested setting")
    }
  }

  private func configureInterception(store: SupportTipStore, session: SKTestSession) async throws {
    // Do not enumerate transactions until this first override is configured and read back.
    try await recordAction(
      "catalog.interception.override", store: store, session: session, collectStoreKitState: false
    ) {
      let expectedError: SKTestFailures.LoadProducts = .generic(.networkError(URLError(.notConnectedToInternet)))
      try await session.setSimulatedError(expectedError, forAPI: .loadProducts)
      let actualError = await session.simulatedError(forAPI: .loadProducts)
      try await recordReceipt(
        phase: "catalog.interception.override", event: "overrideReadback", store: store, session: session,
        collectStoreKitState: false,
        details: ["expectedError": String(describing: expectedError), "actualError": String(describing: actualError)]
      )
      let overrideMatches = actualError == expectedError
      try #require(overrideMatches, "Initial interception override must be ready before observing StoreKit")
    }
  }

  private func purchase(
    _ product: SupportTipProduct, phase: String, expectedImmediateMessage: String? = nil, requiresImmediateMessage: Bool = false,
    store: SupportTipStore, session: SKTestSession
  ) async throws {
    try await recordAction(phase, store: store, session: session) {
      try #require(store.loadState == .loaded, "\(phase): catalog must be loaded before purchase")
      try #require(!store.isLoadingProducts, "\(phase): catalog must not be loading before purchase")
      try #require(!store.isPurchasing, "\(phase): another purchase must not be in flight")
      let containsExpectedProduct = store.products.contains(product)
      try #require(containsExpectedProduct, "\(phase): expected product must still be in the loaded catalog")
      await store.purchase(product)
      // A completed purchase must publish its result before returning, without diagnostic waits.
      if requiresImmediateMessage || expectedImmediateMessage != nil {
        try #require(store.purchaseMessage == expectedImmediateMessage, "\(phase): purchase must return with its result")
        try #require(!store.isPurchasing, "\(phase): purchase must return with purchasing state cleared")
      }
    }
  }

  private func setError<API: FailableStoreKitAPI>(
    _ error: API.Failure?, forAPI api: API, phase: String, store: SupportTipStore, session: SKTestSession
  ) async throws {
    try await recordAction(phase, store: store, session: session) {
      try await requireNoUnfinished(phase: phase, store: store, session: session)
      try await session.setSimulatedError(error, forAPI: api)
      let actualError = await session.simulatedError(forAPI: api)
      try await recordReceipt(
        phase: phase, event: "overrideReadback", store: store, session: session,
        details: ["expectedError": String(describing: error), "actualError": String(describing: actualError)]
      )
      let overrideMatches = actualError == error
      try #require(overrideMatches, "\(phase): simulated error readback must match the requested override")
    }
  }

  private func recordAction(
    _ phase: String, store: SupportTipStore, session: SKTestSession, collectStoreKitState: Bool = true,
    action: () async throws -> Void
  ) async throws {
    try await recordReceipt(
      phase: phase, event: "before", store: store, session: session, collectStoreKitState: collectStoreKitState
    )
    do {
      try await action()
    } catch {
      try await recordReceipt(
        phase: phase, event: "threw", store: store, session: session,
        collectStoreKitState: collectStoreKitState,
        details: ["error": String(describing: error)]
      )
      throw error
    }
    // Initial setup reaches this point only after its exact override readback passed.
    try await recordReceipt(phase: phase, event: "after", store: store, session: session)
  }

  @discardableResult
  private func recordReceipt(
    phase: String, event: String, store: SupportTipStore, session: SKTestSession,
    collectStoreKitState: Bool = true, details: [String: String] = [:]
  ) async throws -> [UInt64] {
    let unfinished = collectStoreKitState ? await unfinishedTipIDs() : []
    let transactions: [[String: Any]] = (collectStoreKitState ? session.allTransactions() : []).map {
      [
        "id": String($0.identifier),
        "originalID": String($0.originalTransactionIdentifier),
        "productID": $0.productIdentifier,
        "state": $0.state.rawValue,
        "pendingAskToBuyConfirmation": $0.pendingAskToBuyConfirmation,
        "hasPurchaseIssue": $0.hasPurchaseIssue
      ]
    }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
    let receipt: [String: Any] = [
      "phase": phase,
      "event": event,
      "details": details,
      "loadState": String(describing: store.loadState),
      "purchaseMessage": store.purchaseMessage as Any? ?? NSNull(),
      "isPurchasing": store.isPurchasing,
      "isLoadingProducts": store.isLoadingProducts,
      "productIDs": store.products.map(\.id).sorted(),
      "storeKitStateCollection": collectStoreKitState ? "collected" : "deferredUntilInitialOverrideConfigured",
      "unfinishedVerifiedTipIDs": collectStoreKitState ? unfinished.map(String.init) as Any : NSNull(),
      "askToBuyEnabled": session.askToBuyEnabled,
      "transactions": collectStoreKitState ? transactions as Any : NSNull()
    ]
    let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
    let json = try #require(String(data: data, encoding: .utf8))
    print("SupportTipStoreKitReceipt \(json)")
    return unfinished
  }

  private func unfinishedTipIDs() async -> [UInt64] {
    var identifiers: [UInt64] = []
    for await result in StoreKit.Transaction.unfinished {
      if case .verified(let transaction) = result, SupportTipStore.productIDs.contains(transaction.productID) {
        identifiers.append(transaction.id)
      }
    }
    return identifiers.sorted()
  }

  /// Verified tip transactions StoreKit still lists as unfinished that the store has not finished itself.
  ///
  /// The store finishes the exact transaction `purchase()` returned, keyed by its unique ID, before it
  /// reports thanks. Under SKTestSession, a repeat purchase of the same consumable can stay listed in
  /// `Transaction.unfinished` after its `finish()` returned, although the first purchase clears; the
  /// adapter's native finish receipts show the call completing. That listing is a local test-session
  /// artifact, so these checks assert the user-visible contract instead: every delivered tip was
  /// finished and acknowledged once, and nothing is left that the store would announce as a new tip.
  private func unacknowledgedTipIDs(_ unfinished: [UInt64], store: SupportTipStore) -> [UInt64] {
    unfinished.filter { !store.handledTransactionIDs.contains($0) }
  }

  private func requireNoUnfinished(phase: String, store: SupportTipStore, session: SKTestSession) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    var unfinished = await unfinishedTipIDs()
    while !unacknowledgedTipIDs(unfinished, store: store).isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(25))
      unfinished = await unfinishedTipIDs()
    }
    unfinished = try await recordReceipt(phase: phase, event: "unfinishedCheck", store: store, session: session)
    let unacknowledged = unacknowledgedTipIDs(unfinished, store: store)
    try #require(unacknowledged.isEmpty, "\(phase): previous verified tip transactions must finish before changing overrides")
  }

  private func requireSuccess(phase: String, store: SupportTipStore, session: SKTestSession) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    var unfinished = await unfinishedTipIDs()
    while store.purchaseMessage != "Thanks for your support!" || store.isPurchasing
            || !unacknowledgedTipIDs(unfinished, store: store).isEmpty,
          ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(25))
      unfinished = await unfinishedTipIDs()
    }
    unfinished = try await recordReceipt(phase: phase, event: "completionCheck", store: store, session: session)
    try #require(store.purchaseMessage == "Thanks for your support!", "\(phase): completed tip must show thanks")
    try #require(!store.isPurchasing, "\(phase): completed tip must clear purchasing state")
    let unacknowledged = unacknowledgedTipIDs(unfinished, store: store)
    try #require(unacknowledged.isEmpty, "\(phase): every verified tip transaction must be finished by the store")
  }
}
#endif
