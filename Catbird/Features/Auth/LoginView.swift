import AuthenticationServices
import OSLog
import Petrel
import SwiftUI

struct LoginView: View {
    // MARK: - Environment
    @Environment(AppState.self) private var appState
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    
    // MARK: - State
    @State private var handle = ""
    @State private var isLoggingIn = false
    @State private var error: String? = nil
    @State private var validationError: String? = nil
    @State private var showInvalidAnimation = false
    @State private var authenticationCancelled = false
    enum Field: Hashable {
        case username
    }
    @FocusState private var focusedField: Field?


    // Logger
    private let logger = Logger(subsystem: "blue.catbird", category: "Auth")
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: adaptiveSpacing(geometry)) {
                    // Logo/Header Area
                    VStack(spacing: adaptiveSpacing(geometry, factor: 0.4)) {
                        Image("CatbirdIcon")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: adaptiveSize(geometry, base: 250, min: 120),
                                   height: adaptiveSize(geometry, base: 250, min: 120))
                            .symbolEffect(.bounce, options: .repeating, value: isLoggingIn)
                            .padding(.bottom, adaptiveSpacing(geometry, factor: 0.2))
                            .shadow(color: colorScheme == .dark ? .black.opacity(0.3) : .white.opacity(0.3), radius: 25, x: 0, y: 1)
                        
                        VStack(spacing: 3) {
                            Text("Catbird")
                                .font(.customSystemFont(size: adaptiveSize(geometry, base: 34, min: 28), weight: .bold, width: 0.7, design: .default, relativeTo: .largeTitle))
                                .foregroundStyle(.primary)
                            
                            Text("for Bluesky")
                                .font(.customSystemFont(size: adaptiveSize(geometry, base: 20, min: 16), weight: .medium, width: 0.7, design: .default, relativeTo: .title))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, adaptiveSpacing(geometry, factor: 1))
                    .padding(.bottom, adaptiveSpacing(geometry, factor: 0.6))
                    
                    // Login Form
                    VStack(spacing: adaptiveSpacing(geometry, factor: 0.7)) {
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
                        .focused($focusedField, equals: .username)
                        .shake(animatableParameter: showInvalidAnimation)
                        .frame(maxWidth: min(geometry.size.width * 0.9, 400))

                        if isLoggingIn {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .controlSize(.small)
                                
                                Text("Authenticating with Bluesky...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: min(geometry.size.width * 0.9, 400))
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
                                .frame(maxWidth: min(geometry.size.width * 0.9, 400))
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
                        VStack(spacing: adaptiveSpacing(geometry, factor: 0.3)) {
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
                        .frame(maxWidth: min(geometry.size.width * 0.9, 400))
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
                    
                    Spacer(minLength: adaptiveSize(geometry, base: 40, min: 20))
                }
                .frame(minHeight: geometry.size.height)
                .padding(.horizontal)
            }
            .onAppear {
                focusedField = .username
            }
            .navigationBarTitleDisplayMode(.inline)
            .background(
                .conicGradient(
                    colors: [.accentColor, colorScheme == .dark ? .black : .white],
                    center: UnitPoint(x: 1.5, y: -0.5), // Values outside 0-1 range
                    angle: .degrees(-45)
                )
            )
        }
        .onChange(of: appState.authState) { oldValue, newValue in
            // Update local error state based on auth manager errors
            if case .error(let message) = newValue {
                error = message
                isLoggingIn = false
            }
        }
    }
    
    // MARK: - Adaptive Layout Helpers
    
    /// Returns spacing that adapts to screen size
    private func adaptiveSpacing(_ geometry: GeometryProxy, factor: CGFloat = 1.0) -> CGFloat {
        let baseSpacing: CGFloat = 24.0
        let minSpacing: CGFloat = 16.0
        
        let screenWidth = geometry.size.width
        let isCompact = horizontalSizeClass == .compact
        
        // Adjust spacing based on screen size and size class
        if screenWidth < 375 {
            // For small screens like iPhone SE
            return max(minSpacing, baseSpacing * 0.6) * factor
        } else if isCompact {
            // For medium screens with compact size class
            return max(minSpacing, baseSpacing * 0.8) * factor
        } else {
            // For large screens
            return baseSpacing * factor
        }
    }
    
    /// Returns a size that adapts to screen dimensions
    private func adaptiveSize(_ geometry: GeometryProxy, base: CGFloat, min: CGFloat) -> CGFloat {
        let screenWidth = geometry.size.width
        let isCompact = horizontalSizeClass == .compact
        
        // Scale size based on screen width while respecting minimum
        if screenWidth < 375 {
            return min
        } else if isCompact {
            let scaleFactor = screenWidth / 428 > 1.0 ? 1.0 : screenWidth / 428
            return max(min, base * scaleFactor)
        } else {
            return base
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
                logger.notice("Authentication was cancelled by user: \(authSessionError._nsError.localizedDescription)")
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


#Preview {
    // Preview provider for LoginView
    @Previewable @State var appState = AppState()
    
        LoginView()
            .environment(appState)
}
