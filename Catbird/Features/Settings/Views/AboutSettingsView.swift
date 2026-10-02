import SwiftUI
import Foundation
import NukeUI
import WebKit
import Nuke

struct AboutSettingsView: View {
    @State private var isClearingCache = false
    @State private var supportStore = SupportTipStore.shared

    init(supportStore: SupportTipStore = .shared) {
        self._supportStore = State(initialValue: supportStore)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    Image("CatbirdIcon")
                        .resizable()
                        .scaledToFit()
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
            
            Section("Support Catbird") {
                Text("Leave an optional tip to support Catbird's development. Thanks for your support!")
                    .appFont(AppTextRole.footnote)
                    .foregroundStyle(.secondary)

                ForEach(supportStore.products) { product in
                    Button {
                        Task { await supportStore.purchase(product) }
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(product.displayName)
                                Spacer(minLength: 12)
                                Text(product.displayPrice)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(product.displayName)
                                Text(product.displayPrice)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .disabled(supportStore.isPurchasing || supportStore.isLoadingProducts)
                    .accessibilityIdentifier("SupportTip.\(product.id)")
                }

                if supportStore.isLoadingProducts || supportStore.isPurchasing {
                    HStack {
                        ProgressView()
                        Text(supportStore.isPurchasing ? "Completing your tip…" : "Loading support options…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }

                if supportStore.loadState == .unavailable || supportStore.loadState == .failed {
                    Text(supportStore.loadState == .failed
                         ? "The App Store couldn't load support options. Please try again."
                         : "Support options are unavailable right now. Please try again later.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("SupportProductsUnavailable")
                    Button("Try Again") {
                        Task { await supportStore.loadProducts(forceReload: true) }
                    }
                    .disabled(supportStore.isPurchasing)
                    .accessibilityIdentifier("SupportProductsRetry")
                }

                if let message = supportStore.purchaseMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .appFont(AppTextRole.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("SupportPurchaseMessage")
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
            await supportStore.loadProducts()
        }
        .refreshable {
            await supportStore.loadProducts(forceReload: true)
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
    
}

#Preview {
  AsyncPreviewContent { _ in
    NavigationStack {
            AboutSettingsView()
        }
  }
}
