import SwiftUI
import NukeUI
import WebKit
import Nuke

// MARK: - Support Tiers

enum SupportTier: CaseIterable {
    case support
    
    var displayTitle: String {
        switch self {
        case .support: return "Support Development"
        }
    }
    
    var stripeURL: URL {
        switch self {
        case .support: return URL(string: "https://buy.stripe.com/4gM00k4Br19e3qzgtf7g402")!
        }
    }
}

struct AboutSettingsView: View {
    @Environment(AppState.self) private var appState
    
    @State private var isClearingCache = false
    @State private var isShowingSupportOptions = false
    
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
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
            
            Section {
                Link(destination: URL(string: "https://bsky.social/about/support/tos")!) {
                    HStack {
                        Text("Terms of Service")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Link(destination: URL(string: "https://bsky.social/about/support/privacy-policy")!) {
                    HStack {
                        Text("Privacy Policy")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Link(destination: URL(string: "https://status.bsky.app")!) {
                    HStack {
                        Text("Status Page")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Section("Support") {
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
                
                // Button {
                //     isShowingSupportOptions = true
                // } label: {
                //     HStack {
                //         Text("Support Development")
                //         Spacer()
                //         Image(systemName: "heart.fill")
                //             .foregroundStyle(.pink)
                //             .appFont(AppTextRole.caption)
                //     }
                // }
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
        .toolbarTitleDisplayMode(.inline)
        .confirmationDialog("Support Development", isPresented: $isShowingSupportOptions, titleVisibility: .visible) {
            Button("Support Catbird (Pay What You Wish)") {
                openSupportLink(SupportTier.support.stripeURL)
            }
            
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Help keep this open source project running. You can choose any amount that feels right to you. Thank you! ❤️")
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
            DispatchQueue.main.async {
                isClearingCache = false
            }
        }
    }
    
    private func openSupportLink(_ url: URL) {
        UIApplication.shared.open(url)
    }
}

#Preview {
    NavigationStack {
        AboutSettingsView()
            .environment(AppState.shared)
    }
}
