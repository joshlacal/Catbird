import SwiftUI
import Foundation

struct AboutSettingsView: View {
    @State private var supportStore = SupportTipStore.shared
    @ScaledMetric(relativeTo: .body) private var minimumRowHeight: CGFloat = 44

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
                        .accessibilityHidden(true)

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

            supportSection

            Section("Legal") {
                // Prefer the app's configured URLs, falling back to Bluesky's policies.
                externalLinkRow(
                    "Terms of Service",
                    destination: LegalConfig.termsOfServiceURL ?? URL(string: "https://bsky.social/about/support/tos")!
                )
                externalLinkRow(
                    "Privacy Policy",
                    destination: LegalConfig.privacyPolicyURL ?? URL(string: "https://bsky.social/about/support/privacy-policy")!
                )
            }

            Section("Status") {
                if let serviceStatusURL = LegalConfig.serviceStatusURL {
                    externalLinkRow("Catbird Service Status", destination: serviceStatusURL)
                }
                externalLinkRow("Bluesky Network Status", destination: URL(string: "https://status.bsky.app")!)
            }

            if let contactURL {
                Section("Contact") {
                    externalLinkRow("Contact Support", destination: contactURL)
                }
            }

            Section {
                LabeledContent("Version", value: Bundle.main.appVersionString)
            }
        }
        .navigationTitle("About & Support")
        .toolbarTitleDisplayMode(.inline)
        .task {
            await supportStore.loadProducts()
        }
        .refreshable {
            await supportStore.loadProducts(forceReload: true)
        }
    }

    // MARK: - Support Catbird

    private var supportSection: some View {
        Section("Support Catbird") {
            Text("Leave an optional tip to support Catbird’s development. Thanks for your support!")
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(supportStore.products) { product in
                tipRow(product)
            }

            if supportStore.isLoadingProducts {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading tips…")
                        .appFont(AppTextRole.body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if supportStore.loadState == .unavailable || supportStore.loadState == .failed {
                Text(supportStore.loadState == .failed
                     ? "Tips couldn’t be loaded from the App Store. Check your connection and try again."
                     : "Tips aren’t available right now. Please try again later.")
                    .appFont(AppTextRole.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("SupportProductsUnavailable")
                Button("Try Again") {
                    Task { await supportStore.loadProducts(forceReload: true) }
                }
                .disabled(supportStore.isPurchasing || supportStore.isLoadingProducts)
                .frame(minHeight: minimumRowHeight)
                .accessibilityIdentifier("SupportProductsRetry")
            }

            if let message = supportStore.purchaseMessage {
                purchaseMessageRow(message)
            }
        }
    }

    private func tipRow(_ product: SupportTipProduct) -> some View {
        let isPurchasingThis = supportStore.purchasingProductID == product.id
        return Button {
            Task { await supportStore.purchase(product) }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    tipName(product)
                    Spacer(minLength: 12)
                    priceCapsule(product, isPurchasing: isPurchasingThis)
                }
                VStack(alignment: .leading, spacing: 8) {
                    tipName(product)
                    priceCapsule(product, isPurchasing: isPurchasingThis)
                }
            }
            .frame(maxWidth: .infinity, minHeight: minimumRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(supportStore.isPurchasing || supportStore.isLoadingProducts)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(product.displayName), \(product.displayPrice)")
        .accessibilityValue(isPurchasingThis ? "Completing your tip" : "")
        .accessibilityHint("Leaves a one-time tip")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("SupportTip.\(product.id)")
    }

    private func tipName(_ product: SupportTipProduct) -> some View {
        Text(product.displayName)
            .appFont(AppTextRole.body)
            .foregroundStyle(Color.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func priceCapsule(_ product: SupportTipProduct, isPurchasing: Bool) -> some View {
        ZStack {
            // Keep the capsule's width stable while the purchase completes.
            Text(product.displayPrice)
                .opacity(isPurchasing ? 0 : 1)
            if isPurchasing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .appFont(AppTextRole.body)
        .fontWeight(.semibold)
        .monospacedDigit()
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .opacity(supportStore.isPurchasing && !isPurchasing ? 0.5 : 1)
    }

    private func purchaseMessageRow(_ message: String) -> some View {
        Group {
            if message == SupportTipStore.thanksMessage {
                Label {
                    Text(message)
                        .appFont(AppTextRole.body)
                        .foregroundStyle(Color.primary)
                } icon: {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(Color.pink)
                }
            } else {
                Text(message)
                    .appFont(AppTextRole.body)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("SupportPurchaseMessage")
    }

    // MARK: - Links

    /// A configured support page, or an email link when only an address is configured.
    private var contactURL: URL? {
        if let supportURL = LegalConfig.supportURL { return supportURL }
        guard let email = LegalConfig.supportEmail else { return nil }
        return URL(string: "mailto:\(email)")
    }

    private func externalLinkRow(_ title: String, destination: URL) -> some View {
        Link(destination: destination) {
            HStack {
                Text(title)
                    .appFont(AppTextRole.body)
                    .foregroundStyle(Color.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(Color.secondary)
                    .accessibilityHidden(true)
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
