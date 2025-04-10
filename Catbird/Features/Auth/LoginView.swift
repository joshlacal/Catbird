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
    @State private var pdsURL = "https://bsky.social"
    @State private var isLoggingIn = false
    @State private var error: String? = nil
    @State private var validationError: String? = nil
    @State private var showInvalidAnimation = false
    @State private var authenticationCancelled = false
    @State private var showAdvancedOptions = false
    @State private var authMode: AuthMode = .selection
    
    enum AuthMode {
        case selection
        case login
        case signup
        case advanced
    }
    
    enum Field: Hashable {
        case username
        case pdsurl
    }
    @FocusState private var focusedField: Field?

    // Logger
    private let logger = Logger(subsystem: "blue.catbird", category: "Auth")
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: adaptiveSpacing(geometry)) {
                    // Logo/Header Area with integrated back button
                    ZStack(alignment: .topLeading) {
                        // Back button for non-selection modes
                        if authMode != .selection {
                            Button {
                                withAnimation(.spring(duration: 0.4)) {
                                    authMode = .selection
                                    showAdvancedOptions = false
                                    error = nil
                                }
                            } label: {
                                Image(systemName: "chevron.left")
                                    .imageScale(.medium)
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                            .padding(.leading, 4)
                            .zIndex(1) // Keep above other elements
                        }
                        
                        // Center logo and text
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
                        .frame(maxWidth: .infinity) // Center the VStack
                    }
                    .padding(.top, adaptiveSpacing(geometry, factor: 0.2))
                    .padding(.bottom, adaptiveSpacing(geometry, factor: 0.3))
                    
                    // Authentication Options
                    VStack(spacing: adaptiveSpacing(geometry, factor: 0.7)) {
                        // Selection Mode - Vertically stacked buttons
                        if authMode == .selection {
                            VStack(spacing: 16) {
                                // Login Button
                                Button {
                                    withAnimation(.spring(duration: 0.4)) {
                                        authMode = .login
                                        focusedField = .username
                                    }
                                } label: {
                                    Text("Sign In")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.accentColor)
                                .buttonBorderShape(.roundedRectangle(radius: 12))
                                
                                // Sign Up Button
                                Button {
                                    withAnimation(.spring(duration: 0.4)) {
                                        authMode = .signup
                                    }
                                } label: {
                                    Text("Create Account")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.accentColor)
                                .buttonBorderShape(.roundedRectangle(radius: 12))
                            }
                            .frame(maxWidth: min(geometry.size.width * 0.9, 400))
                        }
                        
                        // Username field (for login mode)
                        if authMode == .login {
                            Text("Sign in to your account")
                                .font(.headline)
                                .frame(maxWidth: min(geometry.size.width * 0.9, 400), alignment: .leading)
                                .padding(.bottom, 4)
                            
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
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        
                        // PDS URL field (for advanced mode)
                        if authMode == .advanced {
                            Text("Create account on custom PDS")
                                .font(.headline)
                                .frame(maxWidth: min(geometry.size.width * 0.9, 400), alignment: .leading)
                                .padding(.bottom, 4)
                            
                            ValidatingTextField(
                                text: $pdsURL,
                                prompt: "PDS URL (e.g., https://bsky.social)",
                                icon: "link",
                                validationError: validationError,
                                isDisabled: isLoggingIn,
                                keyboardType: .URL,
                                submitLabel: .go,
                                onSubmit: {
                                    handleAdvancedSignup()
                                }
                            )
                            .focused($focusedField, equals: .pdsurl)
                            .shake(animatableParameter: showInvalidAnimation)
                            .frame(maxWidth: min(geometry.size.width * 0.9, 400))
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        
                        // Action button
                        if authMode != .selection {
                            if isLoggingIn {
                                HStack(spacing: 12) {
                                    ProgressView()
                                        .controlSize(.small)
                                    
                                    Text(authModeActionText())
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: min(geometry.size.width * 0.9, 400))
                                .padding()
                                .backgroundStyle(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            } else {
                                Button {
                                    switch authMode {
                                    case .login:
                                        handleLogin()
                                    case .signup:
                                        handleSignup()
                                    case .advanced:
                                        handleAdvancedSignup()
                                    case .selection:
                                        break // Should never happen
                                    }
                                } label: {
                                    Label {
                                        Text(authModeActionButtonText())
                                            .font(.headline)
                                    } icon: {
                                        Image(systemName: authModeActionIcon())
                                    }
                                    .frame(maxWidth: min(geometry.size.width * 0.9, 400))
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isButtonDisabled())
                            }
                        }
                        
                        // Advanced toggle (only in signup mode)
                        if authMode == .signup {
                            Button {
                                withAnimation(.spring(duration: 0.4)) {
                                    showAdvancedOptions.toggle()
                                    authMode = showAdvancedOptions ? .advanced : .signup
                                    if showAdvancedOptions {
                                        focusedField = .pdsurl
                                    }
                                }
                            } label: {
                                Text(showAdvancedOptions ? "Basic Options" : "Advanced Options")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 8)
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
                    
                    // Auth cancelled toast with option to go back
                    if authenticationCancelled {
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                Text("Authentication cancelled")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Button("Return to sign in options") {
                                withAnimation {
                                    authenticationCancelled = false
                                    authMode = .selection
                                    showAdvancedOptions = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(.systemBackground).opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            // Reset the cancelled state after 6 seconds
                            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
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

    
    // MARK: - Helper Methods
    
    private func authModeActionText() -> String {
        switch authMode {
        case .login:
            return "Authenticating..."
        case .signup:
            return "Creating account with Bluesky..."
        case .advanced:
            return "Connecting to custom PDS..."
        case .selection:
            return "" // Should never be used
        }
    }
    
    private func authModeActionButtonText() -> String {
        switch authMode {
        case .login:
            return "Sign In"
        case .signup:
            return "Create Account on Bluesky"
        case .advanced:
            return "Create Account on Custom PDS" // Fixed typo in "Create"
        case .selection:
            return "" // Should never be used
        }
    }
    
    private func authModeActionIcon() -> String {
        switch authMode {
        case .login:
            return "bird.fill"
        case .signup:
            return "person.badge.plus.fill"
        case .advanced:
            return "server.rack"
        case .selection:
            return "" // Should never be used
        }
    }
    
    private func isButtonDisabled() -> Bool {
        switch authMode {
        case .login:
            return handle.isEmpty
        case .signup:
            return false // Always enabled for signup with default PDS
        case .advanced:
            return pdsURL.isEmpty || !isValidURL(pdsURL)
        case .selection:
            return false // Should never be used
        }
    }
    
    private func isValidURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return url.scheme != nil && url.host != nil
    }
    
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
    
    private func handleSignup() {
        // Start signup process with default PDS URL (bsky.social)
        Task {
            await startSignup(pdsURL: URL(string: "https://bsky.social")!)
        }
    }
    
    private func handleAdvancedSignup() {
        // Validate PDS URL
        guard let url = URL(string: pdsURL), isValidURL(pdsURL) else {
            validationError = "Please enter a valid URL"
            showInvalidAnimation = true
            // Reset animation flag after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                showInvalidAnimation = false
            }
            return
        }
        
        // Start signup process with custom PDS URL
        Task {
            await startSignup(pdsURL: url)
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
    
    private func startSignup(pdsURL: URL) async {
        logger.info("Starting signup with PDS URL: \(pdsURL.absoluteString)")
        
        // Update state
        isLoggingIn = true
        error = nil
        
        do {
            // Get auth URL for signup
            let authURL = try await appState.authManager.client?.startSignUpFlow(pdsURL: pdsURL)
            
            guard let authURL else {
                logger.error("Failed to get auth URL for signup")
                error = "Failed to get authentication URL"
                isLoggingIn = false
                return
            }
            
            // Open web authentication session
            do {
                let callbackURL = try await webAuthenticationSession.authenticate(
                    using: authURL,
                    callback: .https(host: "catbird.blue", path: "/oauth/callback"),
                    preferredBrowserSession: .shared, additionalHeaderFields: [:]
                )
                
                logger.info("Signup authentication session completed successfully")
                
                // Process callback
                try await appState.authManager.handleCallback(callbackURL)
                
                // Success is handled via onChange of authState
                
            } catch let authSessionError as ASWebAuthenticationSessionError {
                // User cancelled authentication
                logger.notice("Signup was cancelled by user: \(authSessionError._nsError.localizedDescription)")
                authenticationCancelled = true
                isLoggingIn = false
            } catch {
                // Other authentication errors
                logger.error("Signup authentication error: \(error.localizedDescription)")
                self.error = error.localizedDescription
                isLoggingIn = false
            }
            
        } catch {
            // Error starting signup flow
            logger.error("Error starting signup: \(error.localizedDescription)")
            self.error = error.localizedDescription
            isLoggingIn = false
        }
    }
    
    // MARK: - Adaptive Layout Helpers
    // (Kept the same as original)
    
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
}


#Preview {
    // Preview provider for LoginView
    @Previewable @State var appState = AppState()
    
    LoginView()
        .environment(appState)
}

