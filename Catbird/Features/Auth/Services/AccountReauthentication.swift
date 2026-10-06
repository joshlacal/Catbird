import AuthenticationServices
import OSLog
import SwiftUI

// MARK: - Account Re-authentication

/// Signs in again to a saved account whose session expired, using the same browser
/// sign-in and gateway callback handling as adding an account.
@MainActor
enum AccountReauthentication {
  enum Result: Equatable {
    /// Signed in to the requested account. The auth observer finishes the switch.
    case signedIn(did: String)
    /// Signed in, but to a different account than requested.
    case signedInToDifferentAccount
    case cancelled
    case failed(String)
  }

  private static let logger = Logger(subsystem: "blue.catbird", category: "AccountReauthentication")
  nonisolated private static let timeout: Duration = .seconds(120)

  /// Starts browser sign-in for `did`, prefilled with its saved handle.
  static func signIn(
    toAccount did: String,
    appStateManager: AppStateManager,
    webAuthenticationSession: WebAuthenticationSession
  ) async -> Result {
    let authentication = appStateManager.authentication
    guard let handle = authentication.loginHandle(forAccount: did) else {
      logger.error("Re-authentication has no saved handle for the account")
      appStateManager.discardExpiredAccountIfInactive(did)
      return .failed("Catbird couldn’t find this account’s handle. Remove the account and add it again.")
    }
    do {
      let authURL = try await authentication.login(handle: handle)
      let request = AppState.ReauthenticationRequest(handle: handle, did: did, authURL: authURL)
      return await complete(
        request, appStateManager: appStateManager, webAuthenticationSession: webAuthenticationSession
      )
    } catch {
      logger.error("Re-authentication could not start: \(error.localizedDescription)")
      await settleAbandonedSignIn(for: did, appStateManager: appStateManager)
      return .failed(AuthenticationManager.userFacingMessage(for: error))
    }
  }

  /// Finishes a sign-in whose authorization URL already exists.
  static func complete(
    _ request: AppState.ReauthenticationRequest,
    appStateManager: AppStateManager,
    webAuthenticationSession: WebAuthenticationSession
  ) async -> Result {
    let authentication = appStateManager.authentication
    do {
      let callbackURL = try await authenticate(
        using: request.authURL, webAuthenticationSession: webAuthenticationSession
      )
      try await authentication.handleGatewayCallback(callbackURL)
      guard authentication.state.userDID == request.did else {
        logger.warning("Re-authentication finished for a different account")
        return .signedInToDifferentAccount
      }
      logger.info("Re-authentication finished")
      return .signedIn(did: request.did)
    } catch is ASWebAuthenticationSessionError {
      logger.notice("Re-authentication was cancelled")
      await authentication.cancelGatewayOAuthFlow()
      await settleAbandonedSignIn(for: request.did, appStateManager: appStateManager)
      return .cancelled
    } catch AuthError.timeout {
      logger.error("Re-authentication timed out")
      await authentication.cancelGatewayOAuthFlow()
      await settleAbandonedSignIn(for: request.did, appStateManager: appStateManager)
      return .failed("Signing in took too long. Try again.")
    } catch {
      logger.error("Re-authentication failed: \(error.localizedDescription)")
      await settleAbandonedSignIn(for: request.did, appStateManager: appStateManager)
      return .failed(AuthenticationManager.userFacingMessage(for: error))
    }
  }

  /// Opens the browser sign-in, giving up after `timeout`.
  private static func authenticate(
    using authURL: URL,
    webAuthenticationSession: WebAuthenticationSession
  ) async throws -> URL {
    try await withThrowingTaskGroup(of: URL.self) { group in
      group.addTask { @MainActor in
        if #available(iOS 17.4, macOS 14.4, *) {
          return try await webAuthenticationSession.authenticate(
            using: authURL,
            callback: .https(host: "catbird.blue", path: "/oauth/callback"),
            preferredBrowserSession: .shared,
            additionalHeaderFields: [:]
          )
        } else {
          return try await webAuthenticationSession.authenticate(
            using: authURL,
            callbackURLScheme: "catbird",
            preferredBrowserSession: .shared
          )
        }
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw AuthError.timeout
      }
      defer { group.cancelAll() }
      guard let callbackURL = try await group.next() else { throw AuthError.timeout }
      return callbackURL
    }
  }

  /// Puts authentication back on the active account and forgets the abandoned target.
  private static func settleAbandonedSignIn(for did: String, appStateManager: AppStateManager) async {
    await appStateManager.restoreActiveAccountAfterAbandonedSignIn()
    appStateManager.discardExpiredAccountIfInactive(did)
  }
}

// MARK: - Session Expired Prompt

/// Presents `AppStateManager.pendingReauthenticationPrompt` above an account's content.
/// It stays hidden while a sign-out alert is up and on the sign-in screen, which has its own flow.
struct AccountReauthenticationPromptModifier: ViewModifier {
  let appStateManager: AppStateManager
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession

  private var isPresented: Binding<Bool> {
    Binding(
      get: {
        appStateManager.pendingReauthenticationPrompt != nil
          && appStateManager.authentication.pendingAuthAlert == nil
          && appStateManager.lifecycle.appState != nil
      },
      set: { _ in
        // The buttons resolve the prompt; dismissing alone must not lose it.
      }
    )
  }

  func body(content: Content) -> some View {
    content
      .alert(
        "Session Expired",
        isPresented: isPresented,
        presenting: appStateManager.pendingReauthenticationPrompt
      ) { prompt in
        Button("Sign In Again") {
          signIn(prompt)
        }
        Button("Cancel", role: .cancel) {
          appStateManager.cancelReauthenticationPrompt()
        }
      } message: { prompt in
        Text(prompt.message)
      }
  }

  private func signIn(_ prompt: AppStateManager.ReauthenticationPrompt) {
    appStateManager.pendingReauthenticationPrompt = nil
    let manager = appStateManager
    let session = webAuthenticationSession
    Task { @MainActor in
      let result = await AccountReauthentication.signIn(
        toAccount: prompt.did, appStateManager: manager, webAuthenticationSession: session
      )
      if case .failed(let message) = result {
        manager.lifecycle.appState?.toastManager.show(
          ToastItem(message: message, icon: "exclamationmark.triangle.fill")
        )
      }
    }
  }
}
