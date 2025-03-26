import AuthenticationServices
import OSLog
import Petrel
import SwiftUI

struct LoginView: View {
    // MARK: - Environment
    @Environment(AppState.self) private var appState
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    
    // MARK: - State
    @State private var handle = ""
    @State private var isLoggingIn = false
    @State private var error: String? = nil
    @State private var validationError: String? = nil
    @State private var showInvalidAnimation = false
    @State private var authenticationCancelled = false
    
    // Logger
    private let logger = Logger(subsystem: "blue.catbird", category: "Auth")
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Logo/Header Area
                VStack(spacing: 20) {
                    Image(systemName: "bird.fill")
                        .font(.system(size: 70))
                        .foregroundStyle(
                            .linearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .symbolEffect(.bounce, options: .repeating, value: isLoggingIn)
                        .padding(.bottom, 8)
                    
                    Text("Catbird")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.primary)
                    
                    Text("for Bluesky")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)
                .padding(.bottom, 16)
                
                // Login Form
                VStack(spacing: 16) {
                    ValidatingTextField(
                        text: $handle,
                        prompt: "username.bsky.social",
                        icon: "at",
                        validationError: validationError,
                        isDisabled: isLoggingIn,
                        keyboardType: .emailAddress,
                        submitLabel: .go,
                        onSubmit: {
                            handleLogin()
                        }
                    )
                    .shake(animatableParameter: showInvalidAnimation)

                    if isLoggingIn {
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                            
                            Text("Authenticating with Bluesky...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .backgroundStyle(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Button {
                            handleLogin()
                        } label: {
                            Label {
                                Text("Sign In with Bluesky")
                                    .font(.headline)
                            } icon: {
                                Image(systemName: "bird.fill")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(handle.isEmpty)
                    }
                }
                .padding(.horizontal)
                
                // Error Display
                if let errorMessage = error {
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .symbolEffect(.pulse)
                            Text("Login Error")
                                .font(.headline)
                            Spacer()
                            Button(action: { error = nil }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .imageScale(.large)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Button("Try Again") {
                            // Reset error state
                            error = nil
                            appState.authManager.resetError()
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                    }
                    .padding()
                    .backgroundStyle(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }
                
                // Auth cancelled toast
                if authenticationCancelled {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                        Text("Authentication cancelled")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemBackground).opacity(0.8))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        // Reset the cancelled state after 3 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation {
                                authenticationCancelled = false
                            }
                        }
                    }
                }
                
                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: appState.authState) { oldValue, newValue in
            // Update local error state based on auth manager errors
            if case .error(let message) = newValue {
                error = message
                isLoggingIn = false
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func handleLogin() {
        // Validate handle format
        guard validateHandle(handle) else {
            return
        }
        
        // Start login process
        Task {
            await startLogin()
        }
    }
    
    private func validateHandle(_ handle: String) -> Bool {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Simple validation - must contain a dot or @ symbol
        guard trimmedHandle.contains(".") || trimmedHandle.contains("@") else {
            logger.warning("Invalid handle format: \(trimmedHandle)")
            validationError = "Please include a domain (example.bsky.social)"
            showInvalidAnimation = true
            // Reset animation flag after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                showInvalidAnimation = false
            }
            return false
        }
        
        // Clear validation error
        validationError = nil
        return true
    }
    
    private func startLogin() async {
        logger.info("Starting login for handle: \(handle)")
        
        // Update state
        isLoggingIn = true
        error = nil
        
        // Clean up handle - remove @ prefix and whitespace
        let cleanHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        
        do {
            // Get auth URL
            let authURL = try await appState.authManager.login(handle: cleanHandle)
            
            // Open web authentication session
            do {
                let callbackURL = try await webAuthenticationSession.authenticate(
                    using: authURL,
                    callback: .https(host: "catbird.blue", path: "/oauth/callback"),
                    preferredBrowserSession: .shared, additionalHeaderFields: [:]
                )
                
                logger.info("Authentication session completed successfully")
                
                // Process callback
                try await appState.authManager.handleCallback(callbackURL)
                
                // Success is handled via onChange of authState
                
            } catch let authSessionError as ASWebAuthenticationSessionError {
                // User cancelled authentication
                logger.notice("Authentication was cancelled by user")
                authenticationCancelled = true
                isLoggingIn = false
            } catch {
                // Other authentication errors
                logger.error("Authentication error: \(error.localizedDescription)")
                self.error = error.localizedDescription
                isLoggingIn = false
            }
            
        } catch {
            // Error starting login flow
            logger.error("Error starting login: \(error.localizedDescription)")
            self.error = error.localizedDescription
            isLoggingIn = false
        }
    }
}


