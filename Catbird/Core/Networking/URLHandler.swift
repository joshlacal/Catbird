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
    
    private let logger = Logger(subsystem: "blue.catbird", category: "URLHandler")
    private weak var appState: AppState?
    private weak var navigationManager: AppNavigationManager?
    private var configurationID = UUID()
    private var isInvalidated = false
    @ObservationIgnored private var settingsObservation: URLHandlerSettingsObservation?
    
    #if os(iOS)
    @ObservationIgnored private let presentationAnchor = SceneBrowserPresentationAnchor()
    private var browserPresentationID = UUID()
    #endif
    
    var navigateAction: ((NavigationDestination, Int?) -> Void)?
    var useInAppBrowser = true
    /// Replaces the system browser hand-off (used by tests); `nil` opens the default browser.
    @ObservationIgnored var systemBrowserOpener: (@MainActor (URL) async -> Bool)?
    
    // External intent presenter
    let externalIntentPresenter = ExternalURLIntentPresenter()
    
    // MARK: - Initialization
    
    init() {
        logger.debug("URLHandler initialized")
    }
    
    /// Bind URL delivery to the navigation manager owned by the receiving scene.
    func configure(with appState: AppState, navigationManager: AppNavigationManager) {
        resetPresentationState()
        self.configurationID = UUID()
        self.isInvalidated = false
        self.appState = appState
        self.navigationManager = navigationManager
        let boundConfigurationID = self.configurationID
        self.navigateAction = { [weak self, weak navigationManager] destination, tabIndex in
            guard let self, !self.isInvalidated,
                  self.configurationID == boundConfigurationID else { return }
            navigationManager?.navigate(to: destination, in: tabIndex)
        }
        self.useInAppBrowser = appState.appSettings.useInAppBrowser
        self.settingsObservation = URLHandlerSettingsObservation(
            NotificationCenter.default.addObserver(
                forName: NSNotification.Name("AppSettingsChanged"),
                object: nil,
                queue: .main
            ) { [weak self, weak appState] _ in
                Task { @MainActor [weak self, weak appState] in
                    guard let self, let appState,
                          self.appState === appState, !self.isInvalidated else { return }
                    self.useInAppBrowser = appState.appSettings.useInAppBrowser
                }
            }
        )
    }

    /// Prevent suspended URL work from reaching a disconnected or replaced scene.
    func invalidate() {
        configurationID = UUID()
        isInvalidated = true
        navigateAction = nil
        navigationManager = nil
        appState = nil
        settingsObservation = nil
        resetPresentationState()
    }

    private func resetPresentationState() {
        externalIntentPresenter.clearActiveIntent()
        externalIntentPresenter.pendingIntent = nil
        externalIntentPresenter.lastDeliveredURL = nil
        #if os(iOS)
        presentationAnchor.clear()
        browserPresentationID = UUID()
        #endif
    }

    #if os(iOS)
    func registerTopViewController(_ controller: UIViewController) {
        guard !isInvalidated else { return }
        presentationAnchor.register(controller: controller)
        logger.debug("URLHandler registered local presentation controller: \(type(of: controller))")
    }

    /// The scene host registers its exact window after attaching to UIKit.
    func registerPresentationWindow(_ window: UIWindow) {
        guard !isInvalidated else { return }
        presentationAnchor.register(window: window)
    }
    #endif
    
    // MARK: - URL Handling

    /// Process an incoming URL
    /// Returns an OpenURLAction.Result to indicate if the URL was handled
    @MainActor
    func handle(_ url: URL, tabIndex: Int? = nil) -> OpenURLAction.Result {
        guard !isInvalidated else { return .discarded }
        let requestConfigurationID = configurationID
        // Keep this request's tab stable across asynchronous resolution.
        let effectiveTabIndex = tabIndex ?? navigationManager?.currentTabIndex
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
            return handleMention(urlString, tabIndex: effectiveTabIndex)
        }
        if urlString.starts(with: "tag://") {
            return handleHashtag(urlString, tabIndex: effectiveTabIndex)
        }

        if isBlueskyOrBskyAppURL(url) {
            Task {
                let handled = await routeResolvedURL(url, tabIndex: effectiveTabIndex, configurationID: requestConfigurationID)
                if !handled {
                    logger.warning("❓ URL not recognized: \(url.absoluteString, privacy: .private)")
                }
            }
            return .handled
        }

        if URLSchemePolicy.isWeb(url) {
            if useInAppBrowser && openInAppBrowser(url) {
                return .handled
            }
            return .systemAction
        }

        if URLSchemePolicy.allowsSystemOpen(url) {
            return .systemAction
        }

        logger.warning("❓ Unsupported URL scheme: \(url.scheme ?? "", privacy: .public)")
        return .discarded
    }

    @MainActor
    func handleURL(_ url: URL, tabIndex: Int? = nil) async -> Bool {
        guard !isInvalidated else { return false }
        let requestConfigurationID = configurationID
        // Keep this request's tab stable across asynchronous resolution.
        let effectiveTabIndex = tabIndex ?? navigationManager?.currentTabIndex
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
            _ = handleMention(urlString, tabIndex: effectiveTabIndex)
            return true
        }
        if urlString.starts(with: "tag://") {
            _ = handleHashtag(urlString, tabIndex: effectiveTabIndex)
            return true
        }

        return await routeResolvedURL(url, tabIndex: effectiveTabIndex, configurationID: requestConfigurationID)
    }

    /// Routes a non-callback, non-intent URL to a navigation destination or the
    /// in-app browser. Returns whether the URL was handled.
    @MainActor
    private func routeResolvedURL(_ url: URL, tabIndex: Int?, configurationID: UUID) async -> Bool {
        guard !isInvalidated, self.configurationID == configurationID else { return false }
        if isBlueskyOrBskyAppURL(url) {
            let destination = await parseDestination(from: url)
            guard !isInvalidated, self.configurationID == configurationID else { return false }
            if let destination {
                logger.info("🔗 Parsed URL to navigation destination: \(String(describing: destination))")
                navigateAction?(destination, tabIndex)
                return true
            }
            if selectTabForTabRootURL(url) {
                return true
            }
            // No native screen: show the page instead of silently doing nothing.
            if URLSchemePolicy.isWeb(url) {
                if useInAppBrowser && openInAppBrowser(url) {
                    return true
                }
                return await openInSystemBrowser(url)
            }
            return false
        }

        if URLSchemePolicy.isWeb(url) {
            if useInAppBrowser {
                return openInAppBrowser(url)
            }
            return false
        }

        return false
    }

    private func isBlueskyOrBskyAppURL(_ url: URL) -> Bool {
        URLSchemePolicy.isBluesky(url)
    }

    /// Bluesky links to a top-level screen (Home, Search, Notifications, Messages) select that tab.
    private func selectTabForTabRootURL(_ url: URL) -> Bool {
        guard let navigationManager,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              (components.host ?? "").lowercased() != "go.bsky.app" else { return false }
        var path = components.path
        if (components.scheme ?? "").lowercased() == "bluesky", let host = components.host, !host.isEmpty {
            path = "/\(host)\(path)"
        }
        let segments = path.split(separator: "/").map(String.init)
        let hasQuery = !(components.queryItems ?? []).isEmpty
        let tab: Int
        switch segments.first {
        case nil:
            tab = 0
        case "search" where segments.count == 1 && !hasQuery:
            tab = 1
        case "notifications" where segments.count == 1:
            tab = 2
        case "messages" where segments.count == 1 || (segments.count == 2 && segments[1] != "settings"):
            tab = AppNavigationManager.chatTabIndex
        default:
            return false
        }
        navigationManager.updateCurrentTab(tab)
        navigationManager.tabSelection?(tab)
        #if os(iOS)
        if segments.first == "messages", segments.count == 2 {
            navigationManager.navigate(to: .conversation(segments[1]), in: tab)
        }
        #endif
        return true
    }

    /// Opens a link in the default browser when the in-app browser is off or unavailable.
    private func openInSystemBrowser(_ url: URL) async -> Bool {
        if let systemBrowserOpener {
            return await systemBrowserOpener(url)
        }
        #if os(iOS)
        return await UIApplication.shared.open(url, options: [:])
        #elseif os(macOS)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
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
            if let route = SettingsRoute(routePath: subpath) {
                return .settings(route)
            }
            return .settings(.home)
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
    
    private func handleMention(_ urlString: String, tabIndex: Int?) -> OpenURLAction.Result {
        let encodedDID = String(urlString.dropFirst("mention://".count))
        let did = encodedDID.removingPercentEncoding ?? encodedDID
        navigateAction?(.profile(did), tabIndex)
        return .handled
    }
    
    private func handleHashtag(_ urlString: String, tabIndex: Int?) -> OpenURLAction.Result {
        let tag = String(urlString.dropFirst("tag://".count))
        let decodedTag = tag.removingPercentEncoding ?? tag
        navigateAction?(.hashtag(decodedTag), tabIndex)
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
        guard let window = presentationAnchor.attachedWindow else {
            logger.warning("Cannot open in-app browser without an attached originating window")
            return false
        }
        let requestID = UUID()
        browserPresentationID = requestID
        presentBrowser(
            url, in: window, requestID: requestID,
            configurationID: configurationID, remainingTransitions: 2
        )
        // An attached scene owns this request even while its presenter is busy.
        // Do not redirect a local presentation race into another application.
        return true
        #else
        NSWorkspace.shared.open(url)
        return true
        #endif
    }

    #if os(iOS)
    private func presentBrowser(
        _ url: URL, in window: UIWindow, requestID: UUID,
        configurationID: UUID, remainingTransitions: Int
    ) {
        guard !isInvalidated, self.configurationID == configurationID,
              browserPresentationID == requestID,
              presentationAnchor.attachedWindow === window else { return }
        switch SceneBrowserPresentationAnchor.resolvePresenter(in: window) {
        case .ready(let controller):
            let configuration = SFSafariViewController.Configuration()
            configuration.entersReaderIfAvailable = false
            let safariVC = SFSafariViewController(url: url, configuration: configuration)
            safariVC.preferredControlTintColor = UIColor(named: "AccentColor")
            safariVC.dismissButtonStyle = .close
            safariVC.modalPresentationStyle = .fullScreen
            controller.present(safariVC, animated: true)
        case .transitioning(let coordinator):
            guard remainingTransitions > 0, let coordinator else {
                logger.warning("Originating window has no stable browser presenter")
                return
            }
            coordinator.animate(alongsideTransition: nil) { [weak self, weak window] _ in
                Task { @MainActor [weak self, weak window] in
                    guard let self, let window else { return }
                    self.presentBrowser(
                        url, in: window, requestID: requestID,
                        configurationID: configurationID,
                        remainingTransitions: remainingTransitions - 1
                    )
                }
            }
        case .unavailable:
            logger.warning("Originating window cannot currently present a browser")
        }
    }
    #endif

}

/// The immutable notification token may be released on any thread; the
/// notification center supports removing its observer from that thread.
private final class URLHandlerSettingsObservation: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}

#if os(iOS)
/// Keeps a scene's browser origin alive by identity, without retaining UIKit.
@MainActor
final class SceneBrowserPresentationAnchor {
    enum PresenterResolution {
        case ready(UIViewController)
        case transitioning(UIViewControllerTransitionCoordinator?)
        case unavailable
    }

    private weak var window: UIWindow?
    private weak var controller: UIViewController?
    private var capturedWindow = false

    func register(controller: UIViewController) {
        self.controller = controller
        if let window = controller.viewIfLoaded?.window {
            register(window: window)
        }
    }

    func register(window: UIWindow) {
        self.window = window
        capturedWindow = true
    }

    func clear() {
        window = nil
        controller = nil
        capturedWindow = false
    }

    var attachedWindow: UIWindow? {
        // A controller may register during viewDidLoad, before window attachment.
        // Once an origin was captured, never follow that controller to a new scene.
        if !capturedWindow, let attached = controller?.viewIfLoaded?.window {
            register(window: attached)
        }
        guard let window else { return nil }
        var visible = window.rootViewController
        while let controller = visible {
            if controller.viewIfLoaded?.window === window { return window }
            visible = controller.presentedViewController
        }
        return nil
    }

    static func resolvePresenter(in window: UIWindow) -> PresenterResolution {
        guard !window.isHidden, let root = window.rootViewController else { return .unavailable }
        var current = root
        var visited = Set<ObjectIdentifier>()
        while visited.insert(ObjectIdentifier(current)).inserted {
            if current.isBeingPresented || current.isBeingDismissed {
                return .transitioning(current.transitionCoordinator)
            }
            if let presented = current.presentedViewController {
                guard !presented.isBeingDismissed,
                      presented.viewIfLoaded?.window === window else {
                    return .transitioning(presented.transitionCoordinator ?? current.transitionCoordinator)
                }
                current = presented
                continue
            }
            let visibleChild: UIViewController?
            if let navigation = current as? UINavigationController {
                visibleChild = navigation.visibleViewController
            } else if let tabs = current as? UITabBarController {
                visibleChild = tabs.selectedViewController
            } else if let split = current as? UISplitViewController {
                visibleChild = split.viewControllers.last {
                    $0.viewIfLoaded?.window === window && $0.viewIfLoaded?.isHidden == false
                }
            } else {
                visibleChild = nil
            }
            if let child = visibleChild, child.viewIfLoaded?.window === window {
                current = child
                continue
            }
            guard let view = current.viewIfLoaded, view.window === window,
                  !view.isHidden, view.alpha > 0 else { return .unavailable }
            return .ready(current)
        }
        return .unavailable
    }
}
#endif
