import SwiftUI
import WebKit

struct HelpSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isLoadingWebView = true
    
    var body: some View {
        VStack {
            // Header with information
            VStack(alignment: .leading, spacing: 8) {
                Text("Bluesky Help Center")
                    .font(.headline)
                    .padding(.top)
                
                Text("Find answers to common questions and learn how to use Bluesky's features.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 8)
            
            // Web content
            ZStack {
                BlueskyHelpWebView(isLoading: $isLoadingWebView)
                    .cornerRadius(8)
                    .padding(.horizontal)
                
                if isLoadingWebView {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.1))
                }
            }
            
            Spacer()
            
            // Contact support section
            VStack(spacing: 8) {
                Divider()
                
                Text("Need more help?")
                    .font(.headline)
                    .padding(.top, 4)
                
                Link(destination: URL(string: "https://blueskyweb.zendesk.com/hc/en-us")!) {
                    HStack {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(.blue)
                        
                        Text("Contact Bluesky Support")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .foregroundStyle(.blue)
                    .cornerRadius(8)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
        .navigationTitle("Help")
        .navigationBarTitleDisplayMode(.inline)
    }
}

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

#Preview {
    NavigationStack {
        HelpSettingsView()
            .environment(AppState())
    }
}
