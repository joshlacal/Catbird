import Foundation
import StoreKit
import Testing
@testable import Catbird

@MainActor
struct SupportTipStoreTests {
  @Test func unavailableAndFailedCatalogCanBeRetried() async {
    let client = TipClientFixture()
    let store = SupportTipStore(client: client)
    client.catalog = []
    await store.loadProducts()
    #expect(store.loadState == .unavailable)
    client.catalogError = .unavailable
    await store.loadProducts(forceReload: true)
    #expect(store.loadState == .failed)
    client.catalogError = nil
    client.catalog = [TipClientFixture.product]
    await store.loadProducts(forceReload: true)
    #expect(store.loadState == .loaded)
    #expect(store.products == [TipClientFixture.product])
    #expect(client.requestedIdentifiers.allSatisfy { $0 == SupportTipStore.productIDs })
  }

  @Test func onlyApprovedTipsAppearInAscendingPriceOrder() async {
    let client = TipClientFixture()
    client.catalog = [
      SupportTipProduct(id: "blue.catbird.support.onetime.medium", displayName: "Medium", displayPrice: "$9.99", price: 9.99),
      SupportTipProduct(id: "blue.catbird.support.monthly", displayName: "Monthly", displayPrice: "$3.99", price: 3.99),
      TipClientFixture.product
    ]
    let store = SupportTipStore(client: client)
    await store.loadProducts()
    #expect(store.products.map(\.id) == [TipClientFixture.product.id, "blue.catbird.support.onetime.medium"])
  }

  @Test func successfulTipFinishesAndAllowsAnotherIntentionalTip() async {
    let client = TipClientFixture()
    let recorder = TipFinishRecorder()
    let store = SupportTipStore(client: client)
    await store.loadProducts()
    client.purchaseResult = .success(.verified(transaction(1, recorder: recorder)))
    await store.purchase(TipClientFixture.product)
    client.purchaseResult = .success(.verified(transaction(2, recorder: recorder)))
    await store.purchase(TipClientFixture.product)
    #expect(await recorder.ids == [1, 2])
    #expect(client.purchaseCount == 2)
    #expect(store.purchaseMessage == "Thanks for your support!")
    #expect(!store.isPurchasing)
  }

  @Test func cancellationAndFailureLeavePurchaseAvailableForRetry() async {
    let client = TipClientFixture()
    let store = SupportTipStore(client: client)
    await store.loadProducts()
    client.purchaseResult = .cancelled
    await store.purchase(TipClientFixture.product)
    #expect(store.purchaseMessage == nil)
    client.purchaseError = StoreKitError.userCancelled
    await store.purchase(TipClientFixture.product)
    #expect(store.purchaseMessage == nil)
    client.purchaseError = TipFixtureError.unavailable
    await store.purchase(TipClientFixture.product)
    #expect(store.purchaseMessage == "Your tip couldn’t be completed. Please try again.")
    #expect(!store.isPurchasing)
    client.purchaseError = nil
    client.purchaseResult = .cancelled
    await store.purchase(TipClientFixture.product)
    #expect(store.purchaseMessage == nil)
    #expect(client.purchaseCount == 4)
  }

  @Test func pendingTipCompletesFromUpdatesWithoutAboutScreen() async throws {
    let client = TipClientFixture()
    let recorder = TipFinishRecorder()
    let store = SupportTipStore(client: client)
    await store.loadProducts()
    client.purchaseResult = .pending
    await store.purchase(TipClientFixture.product)
    #expect(store.purchaseMessage == "Your tip is pending approval. Thanks for your support!")
    #expect(await recorder.ids.isEmpty)
    client.updates.continuation.yield(.verified(transaction(3, recorder: recorder)))
    try await eventually { store.purchaseMessage == "Thanks for your support!" }
    #expect(await recorder.ids == [3])
  }

  @Test func appLaunchReconcilesUnfinishedTipsAndStartsOnlyOnce() async throws {
    let client = TipClientFixture()
    let recorder = TipFinishRecorder()
    client.unfinished = [.verified(transaction(4, recorder: recorder))]
    let store = SupportTipStore(client: client)
    store.start()
    store.start()
    try await eventually { store.purchaseMessage == "Thanks for your support!" }
    #expect(await recorder.ids == [4])
    #expect(client.updateSubscriptions == 1)
    #expect(client.requestedIdentifiers.isEmpty)
  }

  @Test func duplicatePurchaseAndUpdateAreFinishedOnce() async throws {
    let client = TipClientFixture()
    let recorder = TipFinishRecorder()
    let store = SupportTipStore(client: client)
    await store.loadProducts()
    let verified = SupportTipVerification.verified(transaction(5, recorder: recorder))
    client.purchaseResult = .success(verified)
    client.updates.continuation.yield(verified)
    await store.purchase(TipClientFixture.product)
    try await eventually { store.purchaseMessage == "Thanks for your support!" }
    #expect(await recorder.ids == [5])
  }

  @Test(arguments: [false, true])
  func duplicatePurchaseWaitsForTheObserversInFlightFinish(cancelPurchaser: Bool) async throws {
    let client = TipClientFixture()
    let finishGate = TipFinishGate()
    let store = SupportTipStore(client: client)
    await store.loadProducts()
    let verified = SupportTipVerification.verified(SupportTipTransaction(
      id: 50, productID: TipClientFixture.product.id, isConsumable: true, isRevoked: false
    ) {
      await finishGate.finish(50)
    })
    client.purchaseResult = .success(verified)

    // Let the application observer claim this transaction and suspend inside finish().
    // The purchase call then receives exactly that same transaction while it is unfinished.
    client.updates.continuation.yield(verified)
    defer { Task { await finishGate.release() } }
    try await requireEventually { await finishGate.startedIDs == [50] }
    var purchaseReturned = false
    let purchaseTask = Task {
      await store.purchase(TipClientFixture.product)
      purchaseReturned = true
    }
    try await requireEventually { client.purchaseCount == 1 }
    if cancelPurchaser { purchaseTask.cancel() }

    // The fixture purchase() has no suspension: seeing its call means the MainActor purchase
    // path has either joined finish() or returned. No timer releases the completion latch.
    #expect(!purchaseReturned)
    #expect(store.isPurchasing)
    #expect(store.purchaseMessage == nil)
    #expect(await finishGate.completedIDs.isEmpty)
    await finishGate.release()
    await purchaseTask.value
    #expect(purchaseReturned)
    #expect(!store.isPurchasing)
    #expect(store.purchaseMessage == "Thanks for your support!")
    #expect(await finishGate.startedIDs == [50])
    #expect(await finishGate.completedIDs == [50])
  }

  @Test func unverifiedAndUnrelatedTransactionsAreNotFinished() async {
    let client = TipClientFixture()
    let recorder = TipFinishRecorder()
    let store = SupportTipStore(client: client)
    await store.loadProducts()
    client.purchaseResult = .success(.unverified(productID: TipClientFixture.product.id))
    await store.purchase(TipClientFixture.product)
    #expect(store.purchaseMessage == "Your tip couldn’t be verified. Please try again later.")
    client.purchaseResult = .success(.verified(transaction(6, productID: "another.product", recorder: recorder)))
    await store.purchase(TipClientFixture.product)
    #expect(await recorder.ids.isEmpty)
    #expect(store.purchaseMessage == nil)
  }

  @Test func storefrontChangeRefreshesLocalizedCatalog() async throws {
    let client = TipClientFixture()
    let store = SupportTipStore(client: client)
    await store.loadProducts()
    let localized = SupportTipProduct(id: TipClientFixture.product.id, displayName: "Small Support", displayPrice: "€5.99", price: 5.99)
    client.catalog = [localized]
    client.storefronts.continuation.yield(())
    try await eventually { store.products == [localized] }
    #expect(client.requestedIdentifiers.count == 2)
  }

  @Test func unknownOrStaleProductCannotStartPurchase() async {
    let client = TipClientFixture()
    let store = SupportTipStore(client: client)
    await store.purchase(TipClientFixture.product)
    #expect(client.purchaseCount == 0)
    #expect(store.purchaseMessage == "This tip is unavailable right now. Please refresh the support options.")
  }

  @Test func cancelledViewLoadDoesNotAbandonReopenedView() async throws {
    let client = TipClientFixture()
    client.suspendCatalogRequest = true
    let store = SupportTipStore(client: client)
    let firstView = Task { await store.loadProducts() }
    try await eventually { client.suspendedCatalog != nil }
    firstView.cancel()
    var reopenedViewEntered = false
    let reopenedView = Task {
      reopenedViewEntered = true
      await store.loadProducts()
    }
    try await eventually { reopenedViewEntered }
    client.suspendedCatalog?.resume(returning: [TipClientFixture.product])
    client.suspendedCatalog = nil
    await firstView.value
    await reopenedView.value
    #expect(client.requestedIdentifiers.count == 1)
    #expect(store.products == [TipClientFixture.product])
    #expect(store.loadState == .loaded)
  }

  private func transaction(_ id: UInt64, productID: String = TipClientFixture.product.id, recorder: TipFinishRecorder) -> SupportTipTransaction {
    SupportTipTransaction(id: id, productID: productID, isConsumable: true, isRevoked: false) {
      await recorder.finish(id)
    }
  }

  private func requireEventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !(await condition()), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    let matched = await condition()
    try #require(matched)
  }

  private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
  }
}

private actor TipFinishRecorder {
  private(set) var ids: [UInt64] = []
  func finish(_ id: UInt64) { ids.append(id) }
}

private actor TipFinishGate {
  private(set) var startedIDs: [UInt64] = []
  private(set) var completedIDs: [UInt64] = []
  private var continuations: [CheckedContinuation<Void, Never>] = []
  private var isReleased = false

  func finish(_ id: UInt64) async {
    startedIDs.append(id)
    if !isReleased {
      await withCheckedContinuation { continuations.append($0) }
    }
    completedIDs.append(id)
  }

  func release() {
    isReleased = true
    continuations.forEach { $0.resume() }
    continuations = []
  }
}

private enum TipFixtureError: Error { case unavailable }

@MainActor
private final class TipClientFixture: SupportTipClient {
  static let product = SupportTipProduct(id: "blue.catbird.support.onetime.small", displayName: "Small Support", displayPrice: "$4.99", price: 4.99)
  var catalog = [product]
  var catalogError: TipFixtureError?
  var purchaseResult: SupportTipPurchaseResult = .cancelled
  var purchaseError: Error?
  var purchaseCount = 0
  var updateSubscriptions = 0
  var requestedIdentifiers: [Set<String>] = []
  var unfinished: [SupportTipVerification] = []
  var suspendCatalogRequest = false
  var suspendedCatalog: CheckedContinuation<[SupportTipProduct], Error>?
  let updates = AsyncStream<SupportTipVerification>.makeStream()
  let storefronts = AsyncStream<Void>.makeStream()

  func products(for identifiers: Set<String>) async throws -> [SupportTipProduct] {
    requestedIdentifiers.append(identifiers)
    if suspendCatalogRequest {
      let result = try await withCheckedThrowingContinuation { suspendedCatalog = $0 }
      try Task.checkCancellation()
      return result
    }
    if let catalogError { throw catalogError }
    return catalog
  }

  func purchase(productID: String) async throws -> SupportTipPurchaseResult {
    purchaseCount += 1
    if let purchaseError { throw purchaseError }
    return purchaseResult
  }

  func transactionUpdates() -> AsyncStream<SupportTipVerification> {
    updateSubscriptions += 1
    return updates.stream
  }

  func unfinishedTransactions() -> AsyncStream<SupportTipVerification> {
    AsyncStream { continuation in
      unfinished.forEach { continuation.yield($0) }
      continuation.finish()
    }
  }

  func storefrontUpdates() -> AsyncStream<Void> { storefronts.stream }
}
