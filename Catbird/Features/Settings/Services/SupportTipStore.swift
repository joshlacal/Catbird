import Foundation
import Observation
import OSLog
import StoreKit

struct SupportTipProduct: Identifiable, Equatable, Sendable {
  let id: String
  let displayName: String
  let displayPrice: String
  let price: Decimal
}

struct SupportTipTransaction: Sendable {
  let id: UInt64
  let productID: String
  let isConsumable: Bool
  let isRevoked: Bool
  let finish: @Sendable () async -> Void
}

enum SupportTipVerification: Sendable {
  case verified(SupportTipTransaction)
  case unverified(productID: String)
}

enum SupportTipPurchaseResult: Sendable {
  case success(SupportTipVerification)
  case pending
  case cancelled
}

/// Keeps StoreKit's signed values inside the adapter, while allowing deterministic lifecycle tests.
@MainActor
protocol SupportTipClient {
  func products(for identifiers: Set<String>) async throws -> [SupportTipProduct]
  func purchase(productID: String) async throws -> SupportTipPurchaseResult
  func transactionUpdates() -> AsyncStream<SupportTipVerification>
  func unfinishedTransactions() -> AsyncStream<SupportTipVerification>
  func storefrontUpdates() -> AsyncStream<Void>
}

/// App-owned purchase state. Start at app launch; opening or closing Settings does not own its lifetime.
@MainActor
@Observable
final class SupportTipStore {
  static let shared = SupportTipStore(client: StoreKitTipClient())
  static let productIDs: Set<String> = [
    "blue.catbird.support.onetime.small",
    "blue.catbird.support.onetime.medium",
    "blue.catbird.support.onetime.large",
    "blue.catbird.support.onetime.extralarge"
  ]

  enum LoadState: Equatable {
    case idle, loading, loaded, unavailable, failed
  }

  private(set) var products: [SupportTipProduct] = []
  private(set) var loadState: LoadState = .idle
  private(set) var purchasingProductID: String?
  private(set) var purchaseMessage: String?

  var isPurchasing: Bool { purchasingProductID != nil }
  var isLoadingProducts: Bool { loadState == .loading }

  @ObservationIgnored private let client: any SupportTipClient
  @ObservationIgnored private var transactionTask: Task<Void, Never>?
  @ObservationIgnored private var unfinishedTask: Task<Void, Never>?
  @ObservationIgnored private var storefrontTask: Task<Void, Never>?
  @ObservationIgnored private var productLoadTask: Task<Void, Never>?
  @ObservationIgnored private var handledTransactionIDs: Set<UInt64> = []
  @ObservationIgnored private var reloadRequested = false
  private static let logger = Logger(subsystem: "blue.catbird", category: "SupportTipStore")

  init(client: any SupportTipClient) {
    self.client = client
  }

  deinit {
    transactionTask?.cancel()
    unfinishedTask?.cancel()
    storefrontTask?.cancel()
    productLoadTask?.cancel()
  }

  func start() {
    guard transactionTask == nil else { return }
    let updates = client.transactionUpdates()
    let unfinished = client.unfinishedTransactions()
    let storefronts = client.storefrontUpdates()
    transactionTask = Task { [weak self] in
      for await update in updates {
        guard !Task.isCancelled else { break }
        await self?.handle(update)
      }
    }
    unfinishedTask = Task { [weak self] in
      for await transaction in unfinished {
        guard !Task.isCancelled else { break }
        await self?.handle(transaction)
      }
    }
    storefrontTask = Task { [weak self] in
      for await _ in storefronts {
        guard !Task.isCancelled else { break }
        await self?.loadProducts(forceReload: true)
      }
    }
  }

  func loadProducts(forceReload: Bool = false) async {
    start()
    if let productLoadTask {
      reloadRequested = reloadRequested || forceReload
      await productLoadTask.value
      return
    }
    guard forceReload || products.isEmpty else { return }

    // A view task can be cancelled on dismissal. Catalog loading belongs to this store, so
    // a newly opened About view joins the same request instead of observing an abandoned load.
    let task = Task { [weak self] in
      await self?.reloadCatalog()
      self?.productLoadTask = nil
    }
    productLoadTask = task
    await task.value
  }

  private func reloadCatalog() async {
    repeat {
      reloadRequested = false
      loadState = .loading
      products = []
      do {
        let loaded = try await client.products(for: Self.productIDs)
        products = loaded.filter { Self.productIDs.contains($0.id) }
          .sorted { $0.price == $1.price ? $0.id < $1.id : $0.price < $1.price }
        loadState = products.isEmpty ? .unavailable : .loaded
      } catch is CancellationError {
        loadState = .failed
      } catch {
        Self.logger.error("Unable to load tip products: \(String(describing: error), privacy: .public)")
        loadState = .failed
      }
    } while reloadRequested && !Task.isCancelled
  }

  func purchase(_ product: SupportTipProduct) async {
    start()
    guard !isPurchasing, !isLoadingProducts else { return }
    guard Self.productIDs.contains(product.id), products.contains(product) else {
      purchaseMessage = "This tip is unavailable right now. Please refresh the support options."
      return
    }
    purchasingProductID = product.id
    purchaseMessage = nil
    defer { purchasingProductID = nil }

    do {
      switch try await client.purchase(productID: product.id) {
      case .success(let verification):
        await handle(verification)
      case .pending:
        purchaseMessage = "Your tip is pending approval. Thanks for your support!"
      case .cancelled:
        break
      }
    } catch StoreKitError.userCancelled {
      // Dismissing the App Store sheet is an ordinary exit, not a purchase failure.
    } catch {
      Self.logger.error("Tip purchase failed: \(String(describing: error), privacy: .public)")
      purchaseMessage = "Your tip couldn't be completed. Please try again."
    }
  }

  private func handle(_ verification: SupportTipVerification) async {
    switch verification {
    case .verified(let transaction):
      guard Self.productIDs.contains(transaction.productID), transaction.isConsumable else { return }
      // Both purchase() and updates can deliver the same transaction. Claim it before suspending.
      guard handledTransactionIDs.insert(transaction.id).inserted else { return }
      await transaction.finish()
      purchaseMessage = transaction.isRevoked
        ? "The App Store updated your tip."
        : "Thanks for your support!"
    case .unverified(let productID):
      guard Self.productIDs.contains(productID) else { return }
      Self.logger.error("Tip transaction could not be verified for \(productID, privacy: .public)")
      purchaseMessage = "Your tip couldn't be verified. Please try again later."
    }
  }
}

@MainActor
final class StoreKitTipClient: SupportTipClient {
  private var availableProducts: [String: Product] = [:]

  func products(for identifiers: Set<String>) async throws -> [SupportTipProduct] {
    let loaded = try await Product.products(for: identifiers).filter { $0.type == .consumable }
    availableProducts = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
    return loaded.map {
      SupportTipProduct(id: $0.id, displayName: $0.displayName, displayPrice: $0.displayPrice, price: $0.price)
    }
  }

  func purchase(productID: String) async throws -> SupportTipPurchaseResult {
    guard let product = availableProducts[productID] else { throw StoreKitError.notAvailableInStorefront }
    switch try await product.purchase() {
    case .success(let verification): return .success(Self.map(verification))
    case .pending: return .pending
    case .userCancelled: return .cancelled
    @unknown default: throw StoreKitError.unknown
    }
  }

  func transactionUpdates() -> AsyncStream<SupportTipVerification> {
    transactionStream(StoreKit.Transaction.updates)
  }

  func unfinishedTransactions() -> AsyncStream<SupportTipVerification> {
    transactionStream(StoreKit.Transaction.unfinished)
  }

  func storefrontUpdates() -> AsyncStream<Void> {
    AsyncStream { continuation in
      let task = Task {
        for await _ in Storefront.updates {
          guard !Task.isCancelled else { break }
          continuation.yield(())
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func transactionStream(_ sequence: StoreKit.Transaction.Transactions) -> AsyncStream<SupportTipVerification> {
    AsyncStream { continuation in
      let task = Task {
        for await verification in sequence {
          guard !Task.isCancelled else { break }
          continuation.yield(Self.map(verification))
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func map(_ verification: VerificationResult<StoreKit.Transaction>) -> SupportTipVerification {
    switch verification {
    case .verified(let transaction):
      return .verified(SupportTipTransaction(
        id: transaction.id,
        productID: transaction.productID,
        isConsumable: transaction.productType == .consumable,
        isRevoked: transaction.revocationDate != nil,
        finish: { await transaction.finish() }
      ))
    case .unverified(let transaction, _):
      return .unverified(productID: transaction.productID)
    }
  }
}
