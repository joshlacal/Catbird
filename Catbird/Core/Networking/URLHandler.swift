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

/// Handles URL navigation and deep links throughout the app
@Observable
final class URLHandler {
    // MARK: - Properties
    
    var targetTabIndex: Int?

    // Logger for URL handling
    private let logger = Logger(subsystem: "blue.catbird", category: "URLHandler")
    
    // The AppState reference - weak to avoid reference cycle
    private weak var appState: AppState?
    
    // Navigation path for app-wide navigation
    
    // Top-level view controller for presenting alerts or handling navigation
    #if os(iOS)
    private weak var topViewController: UIViewController?
    #endif
    
    // Closure for handling navigation actions
    var navigateAction: ((NavigationDestination, Int?) -> Void)?
    
    var useInAppBrowser = true
    
    // MARK: - Initialization
    
    init() {
        logger.debug("URLHandler initialized")
    }
    
    /// Configure the handler with a reference to app state
    func configure(with appState: AppState) {
        self.appState = appState
        
        // Update in-app browser setting from AppSettings
        self.useInAppBrowser = appState.appSettings.useInAppBrowser
        
        // Listen for settings changes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppSettingsChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            let newValue = appState.appSettings.useInAppBrowser
            self.logger.info("📲 URLHandler received AppSettingsChanged notification - updating useInAppBrowser from \(self.useInAppBrowser) to \(newValue)")
            self.useInAppBrowser = newValue
        }
        
        logger.debug("URLHandler configured with AppState reference, useInAppBrowser: \(self.useInAppBrowser)")
    }
    
    /// Register a top-level view controller for presenting UI
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
        // Use the provided tab index or get the current tab from the navigation manager
        targetTabIndex = tabIndex ?? appState?.navigationManager.currentTabIndex
        logger.info("📲 URLHandler processing URL: \(url.absoluteString, privacy: .sensitive), target tab: \(self.targetTabIndex ?? -1)")
        let urlString = url.absoluteString
        
        // First check if the URL matches our OAuth callback path
        if isOAuthCallbackURL(url) {
            logger.info("🔑 Identified as OAuth callback URL")
            handleOAuthCallback(url)
            return .handled
        }
        
        // Handle custom URL schemes first
        switch true {
        case urlString.starts(with: "mention://"):
            return handleMention(urlString)
        case urlString.starts(with: "tag://"):
            return handleHashtag(urlString)
        case urlString.starts(with: "https://bsky.app/"):
            // Start an async task but return immediately
            Task {
                _ = await handleBskyAppURL(urlString)
                // We've already returned from this function, so the result is ignored
            }
            return .handled  // Always handle bsky.app URLs
        case urlString.starts(with: "http://"), urlString.starts(with: "https://"):
            // Handle standard web URLs with in-app browser if enabled
            if useInAppBrowser && openInAppBrowser(url) {
                return .handled
            }
            return .systemAction
        default:
            logger.warning("❓ URL not recognized: \(url.host ?? "nil", privacy: .public)/\(url.path, privacy: .public)")
            return .systemAction
        }
    }
    
    // MARK: - URL Type Handlers
    
    /// Handle mention URLs (mention://did)
    private func handleMention(_ urlString: String) -> OpenURLAction.Result {
        let encodedDID = String(urlString.dropFirst("mention://".count))
        let did = encodedDID.removingPercentEncoding ?? encodedDID
        
        // Use the closure to navigate
        navigateAction?(.profile(did), targetTabIndex)
        return .handled
    }
    
    /// Handle hashtag URLs (tag://hashtag)
    private func handleHashtag(_ urlString: String) -> OpenURLAction.Result {
        let tag = String(urlString.dropFirst("tag://".count))
        logger.info("🏷️ Hashtag tapped: #\(tag)")
        navigateAction?(NavigationDestination.hashtag(tag), targetTabIndex)
        return .handled
    }
    
    /// Handle bsky.app URLs
    private func handleBskyAppURL(_ urlString: String) async -> OpenURLAction.Result {
        if let destination = await parseDestination(from: urlString) {
            logger.info("🔗 Parsed bsky.app URL to navigation destination")
            navigateAction?(destination, targetTabIndex)
            return .handled
        }
        logger.warning("⚠️ Could not parse bsky.app URL: \(urlString, privacy: .sensitive)")
        return .systemAction
    }
    
    // MARK: - URL Parsing
    
    /// Parse a bsky.app URL into a NavigationDestination
    private func parseDestination(from urlString: String) async -> NavigationDestination? {
        let components = urlString.components(separatedBy: "/")
        
        // Handle trending topic feed links
        if components.count >= 7 && components[3] == "profile" &&
           components[4].hasSuffix(".bsky.app") && components[5] == "feed" {
            let feedHost = components[4]
            let feedId = components[6]
                
            // Inside parseDestination
            let did: String
            do {
                if feedHost == "trending.bsky.app" {
                    did = "did:plc:qrz3lhbyuxbeilrc6nekdqme"
                } else {
                    did = try await appState?.atProtoClient?.resolveHandleToDID(handle: feedHost) ?? feedHost
                    logger.info("Resolved feed host \(feedHost) to DID \(did)")
                }
            } catch {
                logger.error("Failed to resolve feed host to DID: \(error). Using host as fallback.")
                did = feedHost
            }
            
            do {
                let uri = try ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.generator/\(feedId)")
                logger.info("📋 Navigating to trending feed: \(feedId)")
                return .feed(uri)
            } catch {
                logger.error("❌ Error creating feed URI: \(error, privacy: .public)")
                return nil
            }
        }
        
        guard components.count >= 5 else {
            logger.warning("⚠️ URL has insufficient components: \(components.count)")
            return nil
        }
        
        let type = components[3]
        let did = components[4]
        
        switch type {
        case "profile":
            if components.count >= 7 && components[5] == "post" {
                return parsePostDestination(did: did, rkey: components[6])
            }
            logger.info("👤 Navigating to profile: \(did, privacy: .private(mask: .hash))")
            return .profile(did)
        case "feed":
            if components.count >= 6 {
                do {
                    let uri = try ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.generator/\(components[5])")
                    logger.info("📋 Navigating to feed: \(components[5])")
                    return .feed(uri)
                } catch {
                    logger.error("❌ Error creating feed URI: \(error, privacy: .public)")
                }
            }
            return nil
        case "lists":
            if components.count >= 6 {
                do {
                    let uri = try ATProtocolURI(uriString: "at://\(did)/app.bsky.graph.list/\(components[5])")
                    logger.info("📋 Navigating to list: \(components[5])")
                    return .list(uri)
                } catch {
                    logger.error("❌ Error creating list URI: \(error, privacy: .public)")
                }
            }
            return nil
        default:
            logger.warning("⚠️ Unknown URL type: \(type)")
            return nil
        }
    }
    
    /// Parse a post URL into a post destination
    private func parsePostDestination(did: String, rkey: String) -> NavigationDestination? {
        do {
            let atUri = try ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.post/\(rkey)")
            logger.info("📝 Navigating to post: \(rkey) by \(did, privacy: .private(mask: .hash))")
            return .post(atUri)
        } catch {
            logger.error("❌ Error creating post URI: \(error, privacy: .public)")
            return nil
        }
    }
    
    // MARK: - OAuth Handling
    
    /// Check if this is an OAuth callback URL we should handle
    private func isOAuthCallbackURL(_ url: URL) -> Bool {
        guard let host = url.host else {
            logger.warning("URL missing host component")
            return false
        }
        
        let isCallback = host == "catbird.blue" && url.path == "/oauth/callback"
        logger.debug("URL check - host: \(host), path: \(url.path), isCallback: \(isCallback)")
        return isCallback
    }
    
    /// Handle OAuth callback URL
    @MainActor
    private func handleOAuthCallback(_ url: URL) {
        logger.info("🔍 Processing OAuth callback")
        
        guard let appState = self.appState else {
            logger.error("❌ Cannot process OAuth callback - AppState reference is nil")
            return
        }
        
        logger.info("Starting OAuth callback task")
        
        // Get current AppState object ID for tracking
        let appStateID = ObjectIdentifier(appState)
        logger.info("Using AppState with object ID: \(String(describing: appStateID))")
        
        // Track auth state before
        let authStateBefore = appState.isAuthenticated
        logger.info("Authentication state before processing: \(authStateBefore)")
        
        Task {
            do {
                logger.info("⏳ Calling AppState.handleOAuthCallback...")
                try await appState.handleOAuthCallback(url)
                
                // Log auth state immediately after
                let authStateAfter = appState.isAuthenticated
                logger.info("✅ OAuth callback completed! Auth state after: \(authStateAfter)")
                
                // Check if auth state wasn't properly updated
                if !authStateAfter {
                    logger.warning("⚠️ Authentication state not updated after callback processing")
                    
                    // Force a state update with a slight delay to allow any other async work to finish
                    try await Task.sleep(for: .seconds(0.2))
                    appState.forceUpdateAuthState(true)
                    
                    logger.info("⚡️ Forced auth state update, current value: \(appState.isAuthenticated)")
                }
                
                // Log again to check if force update worked
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.logger.info("📊 Auth state check (delayed): \(appState.isAuthenticated)")
                }
            } catch {
                logger.error("❌ Error processing OAuth callback: \(error, privacy: .public)")
                
                // Optional: Display an error alert to the user via the top view controller
                DispatchQueue.main.async { [weak self] in
                    self?.showErrorAlert("Authentication failed", error: error)
                }
            }
        }
    }

    // MARK: - In-App Browser
    
    /// Opens a URL in an in-app browser using SFSafariViewController
    /// Returns true if successfully presented, false otherwise
    @MainActor
    private func openInAppBrowser(_ url: URL) -> Bool {
        #if os(iOS)
        guard let topVC = self.topViewController else {
            logger.warning("⚠️ Cannot open in-app browser - no top view controller registered")
            return false
        }
        
        logger.info("🌐 Opening URL in in-app browser: \(url.absoluteString, privacy: .sensitive)")
        
        // Create SFSafariViewController configuration with shared session
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        
        // The SFSafariViewController automatically shares cookies and session data with Safari
        // This is built into how it works and is not configurable
        
        let safariVC = SFSafariViewController(url: url, configuration: configuration)
        safariVC.preferredControlTintColor = UIColor(named: "AccentColor")
        safariVC.dismissButtonStyle = .close
        
        // Use fullscreen presentation for a more immersive experience
        // (You can switch back to .popover if you prefer that style)
        safariVC.modalPresentationStyle = .fullScreen
        
        // Add delegate if you want to respond to navigation events
        // safariVC.delegate = self (would require conforming to SFSafariViewControllerDelegate)
        
        topVC.present(safariVC, animated: true)
        return true
        #else
        // On macOS, use the system browser
        logger.info("🌐 Opening URL in system browser: \(url.absoluteString, privacy: .sensitive)")
        NSWorkspace.shared.open(url)
        return true
        #endif
    }
    
    // MARK: - Helper Methods
    @MainActor
    func handleURL(_ url: URL, tabIndex: Int? = nil) async -> Bool {
        // Use the provided tab index or get the current tab from the navigation manager
        targetTabIndex = tabIndex ?? appState?.navigationManager.currentTabIndex
        logger.info("📲 URLHandler simple processing URL: \(url.absoluteString, privacy: .sensitive), target tab: \(self.targetTabIndex ?? -1)")
        let urlString = url.absoluteString
        
        // OAuth callback handling
        if isOAuthCallbackURL(url) {
            handleOAuthCallback(url)
            return true
        }
        
        // Other URL types
        switch true {
        case urlString.starts(with: "mention://"):
            // Handle mention URL
            let encodedDID = String(urlString.dropFirst("mention://".count))
            let did = encodedDID.removingPercentEncoding ?? encodedDID
            navigateAction?(NavigationDestination.profile(did), targetTabIndex)
            return true
            
        case urlString.starts(with: "tag://"):
            // Handle hashtag URL
            let tag = String(urlString.dropFirst("tag://".count))
            navigateAction?(NavigationDestination.hashtag(tag), targetTabIndex)
            return true
            
        case urlString.starts(with: "https://bsky.app/"):
            // Handle bsky.app URL
            if let destination = await parseDestination(from: urlString) {
                navigateAction?(destination, targetTabIndex)
                return true
            }
            return false
            
        case urlString.starts(with: "http://"), urlString.starts(with: "https://"):
            // Handle web URLs with in-app browser if enabled
            if useInAppBrowser {
                return openInAppBrowser(url)
            }
            return false
            
        default:
            return false
        }
    }

    // MARK: - UI Helpers
    
    /// Display an error alert on the top view controller
    private func showErrorAlert(_ title: String, error: Error) {
        logger.debug("Showing error alert: \(title) - \(error.localizedDescription)")
        #if os(iOS)
        guard let topVC = self.topViewController else { return }
        
        let alert = UIAlertController(
            title: title,
            message: "Error: \(error.localizedDescription)",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        topVC.present(alert, animated: true)
        #else
        // On macOS, we could show an NSAlert or just log the error
        logger.error("Error alert: \(title) - \(error.localizedDescription)")
        #endif
    }
}
