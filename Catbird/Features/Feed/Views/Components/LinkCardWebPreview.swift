import SwiftUI
#if os(iOS)
import UIKit
import WebKit
#endif

extension View {
    /// Long-press menu for an external link card. On iOS the menu peeks at a
    /// live preview of the page, like Safari and Messages do for links.
    func linkCardContextMenu(
        url: URL?,
        opensInAppBrowser: Bool,
        open: @escaping @MainActor (URL) -> Void
    ) -> some View {
        modifier(LinkCardContextMenu(url: url, opensInAppBrowser: opensInAppBrowser, open: open))
    }
}

struct LinkCardContextMenu: ViewModifier {
    let url: URL?
    let opensInAppBrowser: Bool
    let open: @MainActor (URL) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if let url, url.scheme == "http" || url.scheme == "https" {
            #if os(iOS)
            content
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 10))
                .contextMenu {
                    menuItems(for: url)
                } preview: {
                    LinkCardWebPreview(url: url)
                }
            #else
            content
                .contextMenu {
                    menuItems(for: url)
                }
            #endif
        } else {
            content
        }
    }

    @ViewBuilder
    private func menuItems(for url: URL) -> some View {
        Button {
            open(url)
        } label: {
            Label("Open Link", systemImage: "arrow.up.right.square")
        }

        // When links already open in the system browser, "Open Link" covers this.
        if opensInAppBrowser {
            Button {
                PlatformApplication.open(url)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
        }

        Button {
            PlatformApplication.copyToClipboard(url)
        } label: {
            Label("Copy Link", systemImage: "doc.on.doc")
        }

        ShareLink(item: url) {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
    }
}

#if os(iOS)
/// Live webpage shown as the long-press preview of an external link card,
/// the way Safari and Messages peek at links.
///
/// The web view only exists while the preview is on screen, uses a
/// non-persistent data store so peeking leaves no cookies or site data behind,
/// and never autoplays media.
struct LinkCardWebPreview: View {
    let url: URL

    @State private var isLoading = true
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            LinkCardPreviewWebView(url: url, isLoading: $isLoading, didFail: $didFail)
                .opacity(didFail ? 0 : 1)

            if didFail {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Couldn't load preview")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.secondary)
                    Text(url.host() ?? url.absoluteString)
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding()
            } else if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(url.host() ?? url.absoluteString)
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding()
            }
        }
        .frame(width: 360, height: 540)
    }
}

private struct LinkCardPreviewWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var didFail: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LinkCardPreviewWebView

        init(_ parent: LinkCardPreviewWebView) {
            self.parent = parent
        }

        // Show the page as soon as it starts painting rather than waiting for
        // every subresource to finish.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handle(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handle(error)
        }

        private func handle(_ error: Error) {
            // Redirects and our own dismantle cancel in-flight loads; those aren't failures.
            if (error as NSError).code == NSURLErrorCancelled { return }
            parent.isLoading = false
            parent.didFail = true
        }
    }
}
#endif
