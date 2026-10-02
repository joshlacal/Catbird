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
    try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
    store.start()
    await store.loadProducts(forceReload: true)
    try #require(store.loadState == .failed)
    try await session.setSimulatedError(nil, forAPI: .loadProducts)
    await store.loadProducts(forceReload: true)
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
    let rawProducts = try await Product.products(for: expectedIDs)
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

    await store.purchase(tip)
    #expect(store.purchaseMessage == "Thanks for your support!")
    await store.purchase(tip)
    #expect(store.purchaseMessage == "Thanks for your support!")
    let completed = session.allTransactions().filter { $0.productIdentifier == tip.id && $0.state == .purchased }
    #expect(completed.count == 2)
    #expect(Set(completed.map(\.identifier)).count == 2)
    #expect(await unfinishedTipIDs().isEmpty)

    try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
    await store.purchase(tip)
    #expect(store.purchaseMessage == nil)
    #expect(!store.isPurchasing)
    try await session.setSimulatedError(.generic(.unknown), forAPI: .purchase)
    await store.purchase(tip)
    #expect(store.purchaseMessage == "Your tip couldn't be completed. Please try again.")
    try await session.setSimulatedError(.purchase(.productUnavailable), forAPI: .purchase)
    await store.purchase(tip)
    #expect(store.purchaseMessage == "Your tip couldn't be completed. Please try again.")
    try await session.setSimulatedError(nil, forAPI: .purchase)

    // No About view is mounted: approval must reach the application-owned observer.
    session.askToBuyEnabled = true
    await store.purchase(tip)
    #expect(store.purchaseMessage == "Your tip is pending approval. Thanks for your support!")
    let pending = try #require(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
    try session.approveAskToBuyTransaction(identifier: pending.identifier)
    try await waitForThankYou(store)
    #expect(await unfinishedTipIDs().isEmpty)

    // Clearing an error or completing an approval never permanently disables repeated tips.
    session.askToBuyEnabled = false
    await store.purchase(tip)
    #expect(store.purchaseMessage == "Thanks for your support!")
    #expect(!store.isPurchasing)
  }

  private func unfinishedTipIDs() async -> [UInt64] {
    var identifiers: [UInt64] = []
    for await result in StoreKit.Transaction.unfinished {
      if case .verified(let transaction) = result, SupportTipStore.productIDs.contains(transaction.productID) {
        identifiers.append(transaction.id)
      }
    }
    return identifiers
  }

  private func waitForThankYou(_ store: SupportTipStore) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while store.purchaseMessage != "Thanks for your support!", ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(store.purchaseMessage == "Thanks for your support!")
  }
}
#endif
