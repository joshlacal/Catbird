#!/bin/bash

# Script to create a version without monetization features
# This creates a new branch with Stripe code commented out

echo "🔄 Creating monetization-free branch..."

# Create and switch to new branch
git checkout -b main-no-monetization

echo "📝 Modifying AboutSettingsView.swift..."

# Create a temporary file with commented-out Stripe code
cat > /tmp/about_settings_patch.swift << 'EOF'
import SwiftUI
import NukeUI
import WebKit
import Nuke

// MARK: - Support Tiers

/* MONETIZATION DISABLED
enum SupportTier: CaseIterable {
    case support
    
    var displayTitle: String {
        switch self {
        case .support: return "Support Development"
        }
    }
    
    var stripeURL: URL {
        switch self {
        case .support: return URL(string: "https://buy.stripe.com/4gk00m4Br19e3qzgtf7g402")!
        }
    }
}
*/

struct AboutSettingsView: View {
    @Environment(AppState.self) private var appState
    
    @State private var isClearingCache = false
    // @State private var isShowingSupportOptions = false // MONETIZATION DISABLED
    
    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    Image("CatbirdIcon")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 80)
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
                
                /* MONETIZATION DISABLED
                Button {
                    isShowingSupportOptions = true
                } label: {
                    HStack {
                        Text("Support Development")
                        Spacer()
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                            .appFont(AppTextRole.caption)
                    }
                }
                */
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
        .navigationBarTitleDisplayMode(.inline)
        /* MONETIZATION DISABLED
        .confirmationDialog("Support Development", isPresented: $isShowingSupportOptions, titleVisibility: .visible) {
            Button("Support Catbird (Pay What You Wish)") {
                openSupportLink(SupportTier.support.stripeURL)
            }
            
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Help keep this open source project running. You can choose any amount that feels right to you. Thank you! ❤️")
        }
        */
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
    
    /* MONETIZATION DISABLED
    private func openSupportLink(_ url: URL) {
        UIApplication.shared.open(url)
    }
    */
}


#Preview {
    NavigationStack {
        AboutSettingsView()
            .environment(AppState.shared)
    }
}
EOF

# Apply the patch
cp /tmp/about_settings_patch.swift /Users/joshlacalamito/Developer/Catbird+Petrel/Catbird/Catbird/Features/Settings/Views/AboutSettingsView.swift

echo "✅ Monetization code commented out"
echo ""
echo "📋 Summary:"
echo "- Created branch: main-no-monetization"
echo "- Commented out Stripe integration in AboutSettingsView.swift"
echo "- Original code preserved as comments with 'MONETIZATION DISABLED' markers"
echo ""
echo "Next steps:"
echo "1. Test the app to ensure it builds correctly"
echo "2. Commit: git add -A && git commit -m 'Disable monetization features for public release'"
echo "3. For public release, use this branch"
echo "4. To re-enable monetization later, uncomment the marked sections"
