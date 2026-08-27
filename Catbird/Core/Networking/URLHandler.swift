import Foundation
import SwiftUI
import OSLog
#if os(iOS)
import UIKit
import SafariServices
#elseif os(macOS)
import AppKit
#endif
import Petrel
import Observation

/// Handles URL navigation, deep links, and external intents throughout the app
@Observable
@MainActor
final class URLHandler {
    // MARK: - Properties
    
    var targetTabIndex: Int?

    private let logger = Logger(subsystem: "blue.catbird", category: "URLHandler")
    private weak var appState: AppState?
    
    #if os(iOS)
    private weak var topViewController: UIViewController?
    #endif
    
    var navigateAction: ((NavigationDestination, Int?) -> Void)?
    var useInAppBrowser = true
    
    // External intent presenter
    let externalIntentPresenter = ExternalURLIntentPresenter()
    
    // MARK: - Initialization
    
    init() {
        logger.debug("URLHandler initialized")
    }
    
    /// Configure the handler with a reference to app state
    func configure(with appState: AppState) {
        self.appState = appState
        self.useInAppBrowser = appState.appSettings.useInAppBrowser
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppSettingsChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let newValue = appState.appSettings.useInAppBrowser
            self.logger.info("📲 URLHandler updating useInAppBrowser from \(self.useInAppBrowser) to \(newValue)")
                        self.useInAppBrowser = newValue
        }
    }
    
    #if os(iOS)
    func registerTopViewController(_ controller: UIViewController) {
        self.topViewController = controller
        logger.debug("URLHandler registered top view controller: \(type(of: controller))")
    }
    #endif
    
    // MARK: - URL Handling

    /// Process an incoming URL
    /// Returns an OpenURLAction.Result to indicate if the URL was handled
    @MainActor
    func handle(_ url: URL, tabIndex: Int? = nil) -> OpenURLAction.Result {
        targetTabIndex = tabIndex ?? appState?.navigationManager.currentTabIndex
        logger.info("📲 URLHandler processing URL: \(url.absoluteString, privacy: .private)")

        // OAuth callbacks, external intents, and custom schemes are handled
        // synchronously; entity/web URLs are dispatched asynchronously.
        if isOAuthCallbackURL(url) {
            logger.info("🔑 Identified as OAuth callback URL")
            handleOAuthCallback(url)
            return .handled
        }

        if let intent = ExternalURLIntent.parse(from: url) {
            logger.info("🎯 Identified external URL intent: \(String(describing: intent))")
            externalIntentPresenter.handleIntent(intent, from: url, appState: appState)
            return .handled
        }

        let urlString = url.absoluteString
        if urlString.starts(with: "mention://") {
            return handleMention(urlString)
        }
        if urlString.starts(with: "tag://") {
            return handleHashtag(urlString)
        }

        if isBlueskyOrBskyAppURL(url) {
            Task {
                let handled = await routeResolvedURL(url)
                if !handled {
                    logger.warning("❓ URL not recognized: \(url.absoluteString, privacy: .private)")
                }
            }
            return .handled
        }

        if url.scheme == "http" || url.scheme == "https" {
            if useInAppBrowser && openInAppBrowser(url) {
                return .handled
            }
            return .systemAction
        }

        logger.warning("❓ URL not recognized: \(url.absoluteString, privacy: .private)")
        return .systemAction
    }

    @MainActor
    func handleURL(_ url: URL, tabIndex: Int? = nil) async -> Bool {
        targetTabIndex = tabIndex ?? appState?.navigationManager.currentTabIndex
        logger.info("📲 URLHandler handleURL: \(url.absoluteString, privacy: .private)")

        if isOAuthCallbackURL(url) {
            handleOAuthCallback(url)
            return true
        }

        if let intent = ExternalURLIntent.parse(from: url) {
            externalIntentPresenter.handleIntent(intent, from: url, appState: appState)
            return true
        }

        let urlString = url.absoluteString
        if urlString.starts(with: "mention://") {
            _ = handleMention(urlString)
            return true
        }
        if urlString.starts(with: "tag://") {
            _ = handleHashtag(urlString)
            return true
        }

        return await routeResolvedURL(url)
    }

    /// Routes a non-callback, non-intent URL to a navigation destination or the
    /// in-app browser. Returns whether the URL was handled.
    @MainActor
    private func routeResolvedURL(_ url: URL) async -> Bool {
        if isBlueskyOrBskyAppURL(url) {
            if let destination = await parseDestination(from: url) {
                logger.info("🔗 Parsed URL to navigation destination: \(String(describing: destination))")
                navigateAction?(destination, targetTabIndex)
                return true
            }
            if useInAppBrowser && (url.scheme == "http" || url.scheme == "https") {
                return openInAppBrowser(url)
            }
            return false
        }

        if url.scheme == "http" || url.scheme == "https" {
            if useInAppBrowser {
                return openInAppBrowser(url)
            }
            return false
        }

        return false
    }

    private func isBlueskyOrBskyAppURL(_ url: URL) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()
        let host = (url.host ?? "").lowercased()
        return scheme == "bluesky" || host == "bsky.app" || host == "main.bsky.dev" || host == "staging.bsky.app" || host == "go.bsky.app"
    }
    
    // MARK: - URL Parsing
    
    func parseDestination(from urlString: String) async -> NavigationDestination? {
        guard let url = URL(string: urlString) else { return nil }
        return await parseDestination(from: url)
    }

    func parseDestination(from url: URL) async -> NavigationDestination? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return nil
        }

        let scheme = (components.scheme ?? "").lowercased()
        let host = (components.host ?? "").lowercased()
        let path = components.path

        // Reconstruct unified path
        let fullPath: String
        if scheme == "bluesky" {
            if !host.isEmpty && !path.isEmpty {
                fullPath = "/\(host)\(path)"
            } else if !host.isEmpty {
                fullPath = "/\(host)"
            } else {
                fullPath = path
            }
        } else {
            fullPath = path
        }

        let cleanPath = fullPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = cleanPath.split(separator: "/").map {
            $0.removingPercentEncoding ?? String($0)
        }
        let queryItems = components.queryItems ?? []

        guard !segments.isEmpty else { return nil }

        // Route: go.bsky.app/{code}
        if host == "go.bsky.app" {
            return .starterPackShort(segments[0])
        }
        // Route: /start/{actor}/{rkey} or /starter-pack/{actor}/{rkey}
        if segments.count >= 3 && (segments[0] == "start" || segments[0] == "starter-pack") {
            let actor = segments[1]
            let rkey = segments[2]
            let did = await resolveActorToDID(actor)
            if let uri = try? ATProtocolURI(uriString: "at://\(did)/app.bsky.graph.starterpack/\(rkey)") {
                return .starterPack(uri)
            }
            return nil
        }

        // Route: /starter-pack-short/{code}
        if segments.count >= 2 && segments[0] == "starter-pack-short" {
            let code = segments[1]
            return .starterPackShort(code)
        }

        // Route: /notifications/activity?posts={comma-separated AT-URIs}
        if segments.count >= 2 && segments[0] == "notifications" && segments[1] == "activity" {
            let postsParam = queryItems.first(where: { $0.name == "posts" })?.value ?? ""
            var seen = Set<String>()
            var validURIs: [ATProtocolURI] = []
            for str in postsParam.split(separator: ",") {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let uri = try? ATProtocolURI(uriString: trimmed),
                      uri.collection == "app.bsky.feed.post",
                      let recordKey = uri.recordKey,
                      !recordKey.isEmpty else { continue }
                let canonical = uri.uriString()
                if seen.insert(canonical).inserted {
                    validURIs.append(uri)
                    if validURIs.count == 25 {
                        break
                    }
                }
            }
            if !validURIs.isEmpty {
                return .notificationActivity(validURIs)
            }
            return nil
        }

        // Route: /video-feed
        if segments.count >= 1 && segments[0] == "video-feed" {
            return .videoFeed
        }

        // Route: /saved -> bookmarks
        if segments.count >= 1 && (segments[0] == "saved" || segments[0] == "bookmarks") {
            return .bookmarks
        }

        // Route: /hashtag/{tag}
        if segments.count >= 2 && segments[0] == "hashtag" {
            return .hashtag(segments[1])
        }

        // Route: /topic/{topic}
        if segments.count >= 2 && segments[0] == "topic" {
            return .topic(segments[1])
        }

        // Route: /settings/{subpath}
        if segments.count >= 1 && segments[0] == "settings" {
            let subpath = segments.dropFirst().joined(separator: "/")
            if let route = SettingsRoute(routePath: subpath.isEmpty ? "account" : subpath) {
                return .settings(route)
            }
            return .settings(.account)
        }

        // Route: /profile/{actor}/...
        if segments.count >= 2 && segments[0] == "profile" {
            let actor = segments[1]
            let did = await resolveActorToDID(actor)

            if segments.count == 2 {
                return .profile(did)
            }

            if segments.count >= 4 && segments[2] == "post" {
                let rkey = segments[3]
                if segments.count >= 5 {
                    let action = segments[4]
                    let postURI = "at://\(did)/app.bsky.feed.post/\(rkey)"
                    switch action {
                    case "liked-by":
                        return .postLikes(postURI)
                    case "reposted-by":
                        return .postReposts(postURI)
                    case "quotes":
                        return .postQuotes(postURI)
                    default:
                        break
                    }
                }
                if let uri = try? ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.post/\(rkey)") {
                    return .post(uri)
                }
            }

            if segments.count >= 4 && segments[2] == "feed" {
                let rkey = segments[3]
                if let uri = try? ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.generator/\(rkey)") {
                    return .feed(uri)
                }
            }

            if segments.count >= 4 && (segments[2] == "lists" || segments[2] == "list") {
                let rkey = segments[3]
                if let uri = try? ATProtocolURI(uriString: "at://\(did)/app.bsky.graph.list/\(rkey)") {
                    return .list(uri)
                }
            }

            if segments.count >= 4 && (segments[2] == "starter-pack" || segments[2] == "starterpack") {
                let rkey = segments[3]
                if let uri = try? ATProtocolURI(uriString: "at://\(did)/app.bsky.graph.starterpack/\(rkey)") {
                    return .starterPack(uri)
                }
            }

            return .profile(did)
        }

        // Route: /feed/{actor}/{rkey}
        if segments.count >= 3 && segments[0] == "feed" {
            let actor = segments[1]
            let rkey = segments[2]
            let did = await resolveActorToDID(actor)
            if let uri = try? ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.generator/\(rkey)") {
                return .feed(uri)
            }
        }

        // Route: /lists/{actor}/{rkey}
        if segments.count >= 3 && (segments[0] == "lists" || segments[0] == "list") {
            let actor = segments[1]
            let rkey = segments[2]
            let did = await resolveActorToDID(actor)
            if let uri = try? ATProtocolURI(uriString: "at://\(did)/app.bsky.graph.list/\(rkey)") {
                return .list(uri)
            }
        }

        return nil
    }

    private func resolveActorToDID(_ actor: String) async -> String {
        if actor.starts(with: "did:") {
            return actor
        }
        if actor == "trending.bsky.app" {
            return "did:plc:qrz3lhbyuxbeilrc6nekdqme"
        }
        if let handle = try? Handle(handleString: actor) {
            let client: ATProtoClient
            if let appStateClient = appState?.atProtoClient {
                client = appStateClient
            } else {
                client = await ATProtoClient(baseURL: URL(string: "https://public.api.bsky.app")!)
            }
            let params = ComAtprotoIdentityResolveHandle.Parameters(handle: handle)
            do {
                let (_, output) = try await client.com.atproto.identity.resolveHandle(input: params)
                if let did = output?.did {
                    return did.didString()
                }
            } catch {
                // Resolution failed; fall through to returning original actor string
            }
        }
        return actor
    }

    // MARK: - Starter Pack URL Resolution

    /// Resolves a URL to a starter pack ATProtocolURI if it represents a /start, /starter-pack, or starter-pack-short URL.
    func resolveStarterPackURI(from url: URL) async -> ATProtocolURI? {
        if isOAuthCallbackURL(url) { return nil }

        let urlString = url.absoluteString
        if urlString.starts(with: "at://") {
            if let uri = try? ATProtocolURI(uriString: urlString),
               uri.collection == "app.bsky.graph.starterpack" {
                return uri
            }
            return nil
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return nil
        }

        let scheme = (components.scheme ?? "").lowercased()
        let host = (components.host ?? "").lowercased()
        let path = components.path

        // Handle short link go.bsky.app/{code}
        if host == "go.bsky.app" {
            let code = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !code.isEmpty {
                return await resolveStarterPackShortCode(code)
            }
        }

        // Reconstruct unified path
        let fullPath: String
        if scheme == "bluesky" {
            if !host.isEmpty && !path.isEmpty {
                fullPath = "/\(host)\(path)"
            } else if !host.isEmpty {
                fullPath = "/\(host)"
            } else {
                fullPath = path
            }
        } else {
            fullPath = path
        }

        let cleanPath = fullPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let segments = cleanPath.split(separator: "/").map {
            $0.removingPercentEncoding ?? String($0)
        }

        guard !segments.isEmpty else { return nil }

        // Route: /start/{actor}/{rkey} or /starter-pack/{actor}/{rkey}
        if segments.count >= 3 && (segments[0] == "start" || segments[0] == "starter-pack") {
            let actor = segments[1]
            let rkey = segments[2]
            let did = await resolveActorToDID(actor)
            if let uri = try? ATProtocolURI(uriString: "at://\(did)/app.bsky.graph.starterpack/\(rkey)") {
                return uri
            }
            return nil
        }

        // Route: /profile/{actor}/starter-pack/{rkey} or /profile/{actor}/starterpack/{rkey}
        if segments.count >= 4 && segments[0] == "profile" && (segments[2] == "starter-pack" || segments[2] == "starterpack") {
            let actor = segments[1]
            let rkey = segments[3]
            let did = await resolveActorToDID(actor)
            if let uri = try? ATProtocolURI(uriString: "at://\(did)/app.bsky.graph.starterpack/\(rkey)") {
                return uri
            }
            return nil
        }

        // Route: /starter-pack-short/{code}
        if segments.count >= 2 && segments[0] == "starter-pack-short" {
            let code = segments[1]
            return await resolveStarterPackShortCode(code)
        }

        return nil
    }

    /// Resolves a starter pack short code (e.g. from go.bsky.app/{code}) to its ATProtocolURI
    func resolveStarterPackShortCode(_ code: String) async -> ATProtocolURI? {
        guard let url = URL(string: "https://go.bsky.app/\(code)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...399).contains(httpResponse.statusCode) else {
                return nil
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let candidateString = json["url"] as? String ?? json["uri"] as? String ?? json["redirect"] as? String
                if let candidateString {
                    if candidateString.starts(with: "at://"), let uri = try? ATProtocolURI(uriString: candidateString) {
                        return uri
                    } else if let candidateURL = URL(string: candidateString) {
                        let resolvedURI = await resolveStarterPackURI(from: candidateURL)
                        return resolvedURI
                    }
                }
            } else if let location = httpResponse.value(forHTTPHeaderField: "Location"), let locationURL = URL(string: location) {
                let resolvedURI = await resolveStarterPackURI(from: locationURL)
                return resolvedURI
            }
        } catch let resolveError {
            logger.error("Failed to resolve starter pack short code \(code): \(resolveError.localizedDescription)")
        }
        return nil
    }
    
    // MARK: - URL Type Handlers
    
    private func handleMention(_ urlString: String) -> OpenURLAction.Result {
        let encodedDID = String(urlString.dropFirst("mention://".count))
        let did = encodedDID.removingPercentEncoding ?? encodedDID
        navigateAction?(.profile(did), targetTabIndex)
        return .handled
    }
    
    private func handleHashtag(_ urlString: String) -> OpenURLAction.Result {
        let tag = String(urlString.dropFirst("tag://".count))
        let decodedTag = tag.removingPercentEncoding ?? tag
        navigateAction?(.hashtag(decodedTag), targetTabIndex)
        return .handled
    }
    
    // MARK: - OAuth Handling
    
    private func isOAuthCallbackURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return false
        }
        let scheme = (components.scheme ?? "").lowercased()
        let host = (components.host ?? "").lowercased()
        let path = components.path.lowercased()

        // Universal Link: https://catbird.blue/oauth/callback (or https://catbird.blue:443/oauth/callback)
        if scheme == "https" && host == "catbird.blue" && path == "/oauth/callback" {
            return true
        }

        // Custom URL scheme: catbird://oauth/callback or blue.catbird://oauth/callback
        if scheme == "catbird" || scheme == "blue.catbird" {
            if (host == "oauth" && path == "/callback") || (host.isEmpty && path == "/oauth/callback") || (host == "oauth/callback" && path.isEmpty) {
                return true
            }
        }

        return false
    }
    
    @MainActor
    private func handleOAuthCallback(_ url: URL) {
        logger.info("🔍 Processing OAuth callback")
        guard let appState = self.appState else {
            logger.error("❌ Cannot process OAuth callback - AppState reference is nil")
            return
        }
        
        Task {
            do {
                try await appState.handleOAuthCallback(url)
            } catch {
                logger.error("❌ Error processing OAuth callback: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - In-App Browser
    
    @MainActor
    private func openInAppBrowser(_ url: URL) -> Bool {
        #if os(iOS)
        guard let topVC = self.topViewController else {
            logger.warning("⚠️ Cannot open in-app browser - no top view controller registered")
            return false
        }
        
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        
        let safariVC = SFSafariViewController(url: url, configuration: configuration)
        safariVC.preferredControlTintColor = UIColor(named: "AccentColor")
        safariVC.dismissButtonStyle = .close
        safariVC.modalPresentationStyle = .fullScreen
        topVC.present(safariVC, animated: true)
        return true
        #else
        NSWorkspace.shared.open(url)
        return true
        #endif
    }
}
