import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct HelpSettingsView: View {
    var body: some View {
        Form {
            Section("Catbird support") {
                if let contactURL = LegalConfig.supportURL {
                    Link(destination: contactURL) {
                        SettingsNavigationRow(title: "Contact Catbird Support", systemImage: "envelope.fill", family: .support)
                    }
                } else if let email = LegalConfig.supportEmail, let mailURL = URL(string: "mailto:" + email) {
                    Link(destination: mailURL) {
                        SettingsNavigationRow(title: "Contact Catbird Support", systemImage: "envelope.fill", family: .support)
                    }
                } else {
                    Text("Catbird support contact information is available in About & Support when configured.").foregroundStyle(.secondary)
                }
            }
            Section("Bluesky resources") {
                SettingsLink(screen: .blueskyHelpCenter, summary: "Bluesky’s FAQ for the social network", systemImage: "questionmark.bubble", family: .support)
                Link(destination: URL(string: "https://blueskyweb.zendesk.com/hc/en-us")!) {
                    SettingsNavigationRow(title: "Contact Bluesky Support", summary: "Opens Bluesky’s support site", systemImage: "arrow.up.right.square", family: .support)
                }
            }
        }
        .navigationTitle("Get Help")
    }
}

struct BlueskyHelpCenterSettingsView: View {
    @State private var isLoadingWebView = true
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.base) {
            Text("Answers about Bluesky’s social network. This page is provided by Bluesky.")
                .appFont(AppTextRole.subheadline).foregroundStyle(.secondary).padding(.horizontal)
            ZStack {
                BlueskyHelpWebView(isLoading: $isLoadingWebView)
                if isLoadingWebView { ProgressView("Loading Bluesky Help Center…") }
            }
        }
        .navigationTitle("Bluesky Help Center")
    }
}

#if os(iOS)
struct BlueskyHelpWebView: UIViewRepresentable {
    @Binding var isLoading: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        
        // Load the Bluesky help center
        if let url = URL(string: "https://bsky.social/about/faq") {
            webView.load(URLRequest(url: url))
        }
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Updates happen in the coordinator
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: BlueskyHelpWebView
        
        init(_ parent: BlueskyHelpWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
#elseif os(macOS)
struct BlueskyHelpWebView: NSViewRepresentable {
    @Binding var isLoading: Bool
    
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        
        // Load the Bluesky help center
        if let url = URL(string: "https://bsky.social/about/faq") {
            webView.load(URLRequest(url: url))
        }
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Updates happen in the coordinator
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: BlueskyHelpWebView
        
        init(_ parent: BlueskyHelpWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
#endif

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
            HelpSettingsView()
        }
  }
}

