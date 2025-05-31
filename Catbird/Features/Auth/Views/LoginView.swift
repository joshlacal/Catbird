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
    @State private var error: String?
    @State private var validationError: String?
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
            ZStack {
                // Deep fall blue sky background
//                deepBlueSkyBackground
                
                // Hyperrealistic clouds based on "Clouds" by drift
                // https://www.shadertoy.com/view/4tdSWr
                CloudView(
                    opacity: 1.0,          // Full opacity since shader handles blending
                    cloudScale: 1.0,       // Use shader's default scale (1.1 in shader)
                    animationSpeed: 0.5,   // Slower for more realistic movement at 120fps
                    shaderMode: .improved  // Use the drift-based shader
                )
                .allowsHitTesting(false)
                .ignoresSafeArea()
                
                // Main content scroll view
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
                            // Hyperrealistic icon with multiple shadow layers
                            ZStack {
                                // Deep shadow layer
                                Image("CatbirdIcon")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: adaptiveSize(geometry, base: 250, min: 120),
                                           height: adaptiveSize(geometry, base: 250, min: 120))
                                    .blur(radius: 20)
                                    .opacity(0.3)
                                    .offset(y: 15)
                                    .scaleEffect(0.95)
                                
                                // Mid shadow layer
                                Image("CatbirdIcon")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: adaptiveSize(geometry, base: 250, min: 120),
                                           height: adaptiveSize(geometry, base: 250, min: 120))
                                    .blur(radius: 8)
                                    .opacity(0.9)
                                    .offset(y: 8)
                                    .scaleEffect(0.98)
                                
                                // Main icon with realistic lighting
                                mainIconWithLighting(geometry: geometry)
                            }
                            .padding(.bottom, adaptiveSpacing(geometry, factor: 0.2))
                            
                            VStack(spacing: 3) {
                                Text("Catbird")
                                    .font(catbirdTitleFont(geometry: geometry))
                                    .foregroundStyle(.primary)
                                
                                Text("for Bluesky")
                                    .font(catbirdSubtitleFont(geometry: geometry))
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
                            authSelectionButtons
                                .frame(maxWidth: min(geometry.size.width * 0.9, 400))
                        }
                        
                        // Username field (for login mode)
                        if authMode == .login {
                            Text("Sign in to your account")
                                .font(.headline)
                                .frame(maxWidth: min(geometry.size.width * 0.9, 400), alignment: .leading)
                                .padding(.bottom, 4)
                            
                            validatingTextFieldWithBackground(geometry: geometry)
                        }
                        
                        // PDS URL field (for advanced mode)
                        if authMode == .advanced {
                            advancedPDSField(geometry: geometry)
                        }
                        
                        // Action button
                        if authMode != .selection {
                            actionButtonView(geometry: geometry)
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
            }
        }
        .onChange(of: appState.authState) { _, newValue in
            // Update local error state based on auth manager errors
            if case .error(let message) = newValue {
                error = message
                isLoggingIn = false
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private func validatingTextFieldWithBackground(geometry: GeometryProxy) -> some View {
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
        .shake(animatableParameter: showInvalidAnimation, appSettings: appState.appSettings)
        .frame(maxWidth: min(geometry.size.width * 0.9, 400))
        .background(textFieldBackgroundView)
        .modifier(TextFieldShadowModifier(colorScheme: colorScheme))
        .overlay(textFieldOverlayView)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.95).combined(with: .opacity),
            removal: .scale(scale: 1.05).combined(with: .opacity)
        ))
    }
    
    private var textFieldBackgroundView: some View {
        ZStack {
            // Glass morphism background
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
            
            // Inner shadow for depth
            RoundedRectangle(cornerRadius: 16)
                .stroke(textFieldStrokeGradient, lineWidth: 1)
                .blur(radius: 1)
        }
    }
    
    private var textFieldStrokeGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.black.opacity(0.2),
                Color.clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    private var textFieldOverlayView: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(textFieldOverlayGradient, lineWidth: 0.5)
    }
    
    private var textFieldOverlayGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.4),
                Color.white.opacity(0.1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var authSelectionButtons: some View {
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
            .modifier(PrimaryButtonModifier(authMode: authMode))
            
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
            .modifier(PrimaryButtonModifier(authMode: authMode))
        }
    }
    
    private var deepBlueSkyBackground: some View {
        ZStack {
            // Deep fall blue sky - the intense blue of autumn skies
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: colorScheme == .dark ? [
                            Color(red: 0.05, green: 0.08, blue: 0.20),  // Deep midnight blue
                            Color(red: 0.08, green: 0.12, blue: 0.30),  // Rich blue
                            Color(red: 0.03, green: 0.06, blue: 0.15)   // Very dark bottom
                        ] : [
                            Color(red: 0.12, green: 0.25, blue: 0.65),  // Deep fall blue at zenith
                            Color(red: 0.25, green: 0.40, blue: 0.75),  // Medium blue
                            Color(red: 0.35, green: 0.50, blue: 0.80)   // Lighter blue at horizon
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            
            // Atmospheric perspective with subtle radial gradient
            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.05 : 0.10),
                            Color.clear
                        ],
                        center: UnitPoint(x: 0.7, y: 0.3),
                        startRadius: 50,
                        endRadius: 400
                    )
                )
        }
        .ignoresSafeArea()
    }
    
    // MARK: - View Functions
    
    private func mainIconWithLighting(geometry: GeometryProxy) -> some View {
        let iconSize = adaptiveSize(geometry, base: 250, min: 120)
        
        return Image("CatbirdIcon")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: iconSize, height: iconSize)
            .overlay(iconHighlightOverlay)
            .symbolEffect(.bounce, options: .repeating, value: isLoggingIn)
            .modifier(IconShadowModifier(colorScheme: colorScheme))
    }
    
    private var iconHighlightOverlay: some View {
        LinearGradient(
            colors: [
                Color.white.opacity(0.15),
                Color.white.opacity(0.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .mask(
            Image("CatbirdIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
        )
        .blendMode(.colorBurn)
    }
    
    private func advancedPDSField(geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Create account on custom PDS")
                .font(.headline)
                .frame(maxWidth: min(geometry.size.width * 0.9, 400), alignment: .leading)
            
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
            .shake(animatableParameter: showInvalidAnimation, appSettings: appState.appSettings)
            .frame(maxWidth: min(geometry.size.width * 0.9, 400))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
    
    private func actionButtonView(geometry: GeometryProxy) -> some View {
        Group {
            if isLoggingIn {
                loadingButtonView(geometry: geometry)
            } else {
                actionButton(geometry: geometry)
            }
        }
    }
    
    private func loadingButtonView(geometry: GeometryProxy) -> some View {
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
    }
    
    private func actionButton(geometry: GeometryProxy) -> some View {
        Button {
            handleActionButtonTap()
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
    
    private func handleActionButtonTap() {
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
    }
    
    // MARK: - Font Helpers
    
    private func catbirdTitleFont(geometry: GeometryProxy) -> Font {
        let size = adaptiveSize(geometry, base: 34, min: 28)
        return .customSystemFont(
            size: size, 
            weight: .bold, 
            width: 120, 
            design: .default, 
            relativeTo: .largeTitle
        )
    }
    
    private func catbirdSubtitleFont(geometry: GeometryProxy) -> Font {
        let size = adaptiveSize(geometry, base: 20, min: 16)
        return .customSystemFont(
            size: size, 
            weight: .medium, 
            width: 120, 
            design: .default, 
            relativeTo: .title
        )
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
                let callbackURL: URL
                if #available(iOS 17.4, *) {
                    callbackURL = try await webAuthenticationSession.authenticate(
                      using: authURL,
                      callback: .https(host: "catbird.blue", path: "/oauth/callback"),
                      preferredBrowserSession: .shared,
                      additionalHeaderFields: [:]
                    )
                } else {
                    // Fallback on earlier versions
                    callbackURL = try await webAuthenticationSession.authenticate(using: URL(string: "https://catbird/oauth/callback")!, callbackURLScheme: "catbird", preferredBrowserSession: .shared
                      )
                }

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

// MARK: - View Modifiers

struct TextFieldShadowModifier: ViewModifier {
    let colorScheme: ColorScheme
    
    func body(content: Content) -> some View {
        content
            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
            .shadow(color: .white.opacity(colorScheme == .dark ? 0.1 : 0.5), radius: 10, x: 0, y: -5)
    }
}

struct IconShadowModifier: ViewModifier {
    let colorScheme: ColorScheme
    
    func body(content: Content) -> some View {
        content
            .shadow(color: colorScheme == .dark ? .black.opacity(0.6) : .black.opacity(0.2), radius: 1, x: 0, y: 1)
            .shadow(color: colorScheme == .dark ? .white.opacity(0.1) : .white.opacity(0.8), radius: 1, x: 0, y: -1)
    }
}

struct PrimaryButtonModifier: ViewModifier {
    let authMode: LoginView.AuthMode
    
    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            .tint(.accentColor)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .shadow(color: .accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
            .scaleEffect(authMode == .selection ? 1.0 : 0.95)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: authMode)
    }
}
