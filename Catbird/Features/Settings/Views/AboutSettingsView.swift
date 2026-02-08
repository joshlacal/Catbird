import SwiftUI
import Foundation
import NukeUI
import WebKit
import Nuke
import StoreKit
import OSLog

struct AboutSettingsView: View {
    @Environment(AppState.self) private var appState
    private static let storeLogger = Logger(subsystem: "blue.catbird", category: "AboutSettingsView.StoreKit")
    private static let subscriptionDateStyle: Date.FormatStyle = .dateTime.month().day().year()
    
    @State private var isClearingCache = false
    
    // MARK: - StoreKit State
    @State private var oneTimeSupportProducts: [Product] = []
    @State private var subscriptionProducts: [Product] = []
    @State private var isLoadingProducts = false
    @State private var isPurchasing = false
    @State private var purchaseMessage: String?
    @State private var subscriptionStatuses: [Product.SubscriptionInfo.Status] = []
    @State private var transactionUpdatesTask: Task<Void, Never>?
    @State private var storefrontUpdatesTask: Task<Void, Never>?
    
    // Product identifiers configured in App Store Connect or StoreKit configuration
    private let oneTimeProductIDs: Set<String> = [
        "blue.catbird.support.onetime.small",
        "blue.catbird.support.onetime.medium",
        "blue.catbird.support.onetime.large",
        "blue.catbird.support.onetime.extralarge"
    ]
    
    private let subscriptionProductIDs: Set<String> = [
        "blue.catbird.support.monthly",
        "blue.catbird.support.yearly"
    ]
    
    private var shouldShowSupportSection: Bool {
        !Bundle.main.isTestFlightBuild
    }
    
    private var activeSubscriptionMessage: String? {
        guard let status = subscriptionStatuses.first(where: { $0.state == .subscribed }) else { return nil }
        var messageComponents: [String] = []
        if case .verified(let renewalInfo) = status.renewalInfo {
            if let product = subscriptionProducts.first(where: { $0.id == renewalInfo.currentProductID }) {
                messageComponents.append(product.displayName)
            } else {
                messageComponents.append("Active Subscription")
            }
            if let renewalDate = renewalInfo.renewalDate {
                messageComponents.append("Renews \(renewalDate.formatted(Self.subscriptionDateStyle))")
            }
            if let transaction = verifiedTransaction(for: status), let expiration = transaction.expirationDate, messageComponents.allSatisfy({ !$0.contains("Renews") }) {
                messageComponents.append("Expires \(expiration.formatted(Self.subscriptionDateStyle))")
            }
            if !renewalInfo.willAutoRenew {
                messageComponents.append("Auto-renew off")
            }
        } else if let transaction = verifiedTransaction(for: status), let expiration = transaction.expirationDate {
            if let product = subscriptionProducts.first(where: { $0.id == transaction.productID }) {
                messageComponents.append(product.displayName)
            } else {
                messageComponents.append("Active Subscription")
            }
            messageComponents.append("Expires \(expiration.formatted(Self.subscriptionDateStyle))")
        } else {
            messageComponents.append("Active Subscription")
        }
        return messageComponents.joined(separator: " • ")
    }
    
    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    Image("CatbirdIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    
                    VStack(spacing: 8) {
                        Text("Catbird")
                            .appFont(AppTextRole.title2)
                            .fontWeight(.semibold)
                        
                        Text("A native Bluesky client")
                            .appFont(AppTextRole.subheadline)
                            .foregroundStyle(.secondary)

                        Text("Catbird is an independent client and is not affiliated with Bluesky PBC.")
                            .appFont(AppTextRole.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            
            // MARK: - Support Catbird (In‑App Purchases)
            if shouldShowSupportSection {
                Section("Support Catbird") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Catbird is free and open‑source. If you find it useful, you can support ongoing development with an optional one‑time contribution or a recurring subscription. These do not unlock features.")
                            .appFont(AppTextRole.footnote)
                            .foregroundStyle(.secondary)
                    }
                    
                    if let activeSubscriptionMessage {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.tint)
                            Text(activeSubscriptionMessage)
                                .appFont(AppTextRole.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    
                    if !subscriptionProducts.isEmpty {
                        ForEach(subscriptionProducts.sorted(by: { $0.price < $1.price }), id: \.id) { product in
                            Button {
                                Task { await purchase(product) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(product.displayName)
                                        Text(product.displayPrice)
                                            .foregroundStyle(.secondary)
                                            .appFont(AppTextRole.caption)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.forward.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .disabled(isPurchasing)
                        }
                    }
                    
                    if !oneTimeSupportProducts.isEmpty {
                        ForEach(oneTimeSupportProducts.sorted(by: { $0.price < $1.price }), id: \.id) { product in
                            Button {
                                Task { await purchase(product) }
                            } label: {
                                HStack {
                                    Text(product.displayName)
                                    Spacer()
                                    Text(product.displayPrice)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(isPurchasing)
                        }
                    }
                    
                    if subscriptionProducts.isEmpty && oneTimeSupportProducts.isEmpty {
                        HStack {
                            if isLoadingProducts {
                                ProgressView()
                                Text("Loading support options…")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Support options unavailable. Pull to refresh or try again later.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    #if os(iOS)
                    HStack {
                        Button("Restore Purchases") { Task { await restorePurchases() } }
                            .disabled(isPurchasing)
                        Spacer()
                        Button("Manage Subscription") { Task { await showManageSubscriptions() } }
                            .disabled(subscriptionProducts.isEmpty)
                    }
                    #endif
                    
                    if let message = purchaseMessage {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .appFont(AppTextRole.caption)
                            .accessibilityIdentifier("SupportPurchaseMessage")
                    }
                }
            }
            
            Section {
                // Terms of Service (prefer app's configured URL, fallback to Bluesky)
                let tosURL = LegalConfig.termsOfServiceURL ?? URL(string: "https://bsky.social/about/support/tos")!
                Link(destination: tosURL) {
                    HStack {
                        Text("Terms of Service")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // Privacy Policy (prefer app's configured URL, fallback to Bluesky)
                let privacyURL = LegalConfig.privacyPolicyURL ?? URL(string: "https://bsky.social/about/support/privacy-policy")!
                Link(destination: privacyURL) {
                    HStack {
                        Text("Privacy Policy")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                // App/service status (show Catbird status if provided, otherwise show Bluesky network status)
                if let serviceStatusURL = LegalConfig.serviceStatusURL {
                    Link(destination: serviceStatusURL) {
                        HStack {
                            Text("Service Status")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Link(destination: URL(string: "https://status.bsky.app")!) {
                    HStack {
                        Text("Bluesky Network Status")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                NavigationLink(destination: OpenSourceLicensesView()) {
                    Text("Open Source Licenses")
                }
            }
            
            Section("Support") {
                // Optional: Contact Support (URL or mailto) if configured in Info.plist
                if let contactURL = LegalConfig.supportURL {
                    Link(destination: contactURL) {
                        HStack {
                            Image(systemName: "envelope.fill").foregroundStyle(.tint)
                            Text("Contact Support")
                        }
                    }
                } else if let email = LegalConfig.supportEmail, let mailURL = URL(string: "mailto:\(email)") {
                    Link(destination: mailURL) {
                        HStack {
                            Image(systemName: "envelope.fill").foregroundStyle(.tint)
                            Text("Contact Support")
                        }
                    }
                }

                NavigationLink("System Log") {
                    SystemLogView()
                }
                
                Button {
                    clearImageCache()
                } label: {
                    if isClearingCache {
                        HStack {
                            Text("Clearing cache...")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Text("Clear Image Cache")
                    }
                }
                .disabled(isClearingCache)
            }
            
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.appVersionString)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("Build")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("About")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
        .task {
            guard shouldShowSupportSection else { return }
            await initializeSupportStore()
        }
        .onDisappear {
            stopStoreObservers()
        }
        .safeAreaInset(edge: .top) {
            // Disclaimer (non‑affiliation)
            VStack(alignment: .leading, spacing: 0) {
                Text("") // spacer for inset consistency if needed
            }
            .frame(height: 0)
        }
    }
    
    private func clearImageCache() {
        isClearingCache = true
        
        // Clear Nuke image cache
        ImagePipeline.shared.cache.removeAll()
        
        // Clear WKWebView cache
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) {
            Task { @MainActor in
                isClearingCache = false
            }
        }
    }
    
    // MARK: - StoreKit
    @MainActor
    private func initializeSupportStore() async {
        await loadProducts(forceReload: false)
        startStoreObservers()
    }

    @MainActor
    private func loadProducts(forceReload: Bool) async {
        guard shouldShowSupportSection else { return }
        if isLoadingProducts && !forceReload { return }
        let needsInitialLoad = oneTimeSupportProducts.isEmpty && subscriptionProducts.isEmpty
        if !forceReload && !needsInitialLoad {
            await refreshSubscriptionStatus()
            return
        }

        isLoadingProducts = true
        purchaseMessage = nil
        defer { isLoadingProducts = false }

        do {
            let ids = oneTimeProductIDs.union(subscriptionProductIDs)
            let products = try await Product.products(for: Array(ids))
            oneTimeSupportProducts = products.filter { $0.type == .consumable }
            subscriptionProducts = products.filter { $0.type == .autoRenewable }
            await refreshSubscriptionStatus()
        } catch {
            Self.storeLogger.error("Failed to load support products: \(String(describing: error), privacy: .public)")
            purchaseMessage = "Unable to load support options. Please try again later."
        }
    }

    @MainActor
    private func refreshSubscriptionStatus() async {
        guard !subscriptionProducts.isEmpty else {
            subscriptionStatuses = []
            return
        }

        var collectedStatuses: [Product.SubscriptionInfo.Status] = []

        for product in subscriptionProducts {
            guard let subscription = product.subscription else { continue }
            do {
                let statuses = try await subscription.status
                collectedStatuses.append(contentsOf: statuses)
            } catch {
                Self.storeLogger.error("Failed to fetch subscription status for \(product.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        subscriptionStatuses = collectedStatuses
    }

    @MainActor
    private func verifiedTransaction(for status: Product.SubscriptionInfo.Status) -> StoreKit.Transaction? {
        if case .verified(let transaction) = status.transaction {
            return transaction
        }
        return nil
    }

    @MainActor
    private func startStoreObservers() {
        if transactionUpdatesTask == nil {
            transactionUpdatesTask = Task { await monitorTransactionUpdates() }
        }

        if storefrontUpdatesTask == nil {
            storefrontUpdatesTask = Task { await monitorStorefrontUpdates() }
        }
    }

    @MainActor
    private func stopStoreObservers() {
        transactionUpdatesTask?.cancel()
        transactionUpdatesTask = nil
        storefrontUpdatesTask?.cancel()
        storefrontUpdatesTask = nil
    }

    private func monitorTransactionUpdates() async {
        for await result in StoreKit.Transaction.updates {
            if Task.isCancelled { break }
            await handle(transactionUpdate: result)
        }
    }

    private func monitorStorefrontUpdates() async {
        for await storefront in Storefront.updates {
            if Task.isCancelled { break }
            await handleStorefrontChange(storefront)
        }
    }

    @MainActor
    private func handle(transactionUpdate result: VerificationResult<StoreKit.Transaction>) async {
        switch result {
        case .verified(let transaction):
            await transaction.finish()
            purchaseMessage = "Purchase updated from the App Store."
            await refreshSubscriptionStatus()
        case .unverified(let transaction, let error):
            Self.storeLogger.error("Unverified transaction for \(transaction.productID, privacy: .public): \(String(describing: error), privacy: .public)")
            purchaseMessage = "Purchase could not be verified."
        }
    }

    @MainActor
    private func handleStorefrontChange(_ storefront: Storefront) async {
        Self.storeLogger.info("Storefront changed to \(storefront.id, privacy: .public)")
        await loadProducts(forceReload: true)
    }

    @MainActor
    private func purchase(_ product: Product) async {
        guard !isPurchasing else { return }

        isPurchasing = true
        defer { isPurchasing = false }
        purchaseMessage = nil

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    purchaseMessage = "Thank you for supporting Catbird!"
                    await refreshSubscriptionStatus()
                case .unverified(let transaction, let error):
                    Self.storeLogger.error("Purchase verification failed for \(transaction.productID, privacy: .public): \(String(describing: error), privacy: .public)")
                    purchaseMessage = "Purchase could not be verified."
                }
            case .pending:
                purchaseMessage = "Purchase is pending approval."
            case .userCancelled:
                break
            @unknown default:
                purchaseMessage = "Purchase completed with an unexpected result."
            }
        } catch {
            Self.storeLogger.error("Purchase failed for \(product.id, privacy: .public): \(String(describing: error), privacy: .public)")
            purchaseMessage = purchaseErrorMessage(for: error)
        }
    }

    #if os(iOS)
    @MainActor
    private func showManageSubscriptions() async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            purchaseMessage = "Unable to open subscription management right now."
            return
        }

        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            Self.storeLogger.error("Failed to present Manage Subscription: \(String(describing: error), privacy: .public)")
            purchaseMessage = purchaseErrorMessage(for: error)
        }
    }
    #endif

    @MainActor
    private func restorePurchases() async {
        guard !isPurchasing else { return }

        isPurchasing = true
        defer { isPurchasing = false }
        purchaseMessage = nil

        do {
            try await AppStore.sync()
            purchaseMessage = "Restored purchases. Any active support options will sync shortly."
            await refreshSubscriptionStatus()
        } catch {
            Self.storeLogger.error("Failed to restore purchases: \(String(describing: error), privacy: .public)")
            purchaseMessage = purchaseErrorMessage(for: error)
        }
    }

    private func purchaseErrorMessage(for error: Error) -> String {
        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .networkError(_):
                return "The App Store is unavailable. Check your connection and try again."
            case .systemError(_):
                return "The App Store encountered a temporary issue. Please try again later."
            case .notAvailableInStorefront:
                return "This support option is not available in your region."
            case .notEntitled:
                return "This build is not entitled to use In-App Purchases."
            case .userCancelled:
                return "Purchase cancelled."
            default:
                break
            }
        }

        return "Purchase failed. Please try again later."
    }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
    NavigationStack {
        AboutSettingsView()
            .applyAppStateEnvironment(appState)
    }
}
