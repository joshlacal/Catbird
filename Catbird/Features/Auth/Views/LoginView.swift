import AuthenticationServices
import OSLog
import Petrel
import SwiftUI

struct LoginView: View {
    // MARK: - Properties
    /// Indicates if this LoginView is being used to add a new account (vs initial login or re-authentication)
    let isAddingNewAccount: Bool
    
    // MARK: - Environment
    @Environment(AppStateManager.self) private var appStateManager
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    
    // MARK: - Initialization
    init(isAddingNewAccount: Bool = false) {
        self.isAddingNewAccount = isAddingNewAccount
    }
    
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
    @State private var loginProgress: LoginProgress = .idle
    @State private var showDebugInfo = false
    @State private var biometricAuthAvailable = false
    
    // Advanced AppView configuration
    @State private var customAppViewDID = "did:web:api.bsky.app#bsky_appview"
    @State private var customChatDID = "did:web:api.bsky.chat#bsky_chat"
    @State private var showAppViewAdvancedOptions = false
    
    // Task cancellation support
    @State private var authenticationTask: Task<Void, Never>?
    @State private var timeoutCountdown: Int = 60
    @State private var showTimeoutCountdown = false
    
    // Track if we've already started re-authentication to prevent multiple OAuth prompts
    @State private var hasStartedReAuthentication = false
    
    enum LoginProgress {
        case idle
        case startingAuth
        case authenticating
        case processingCallback
        case completing
    }
    
    enum AuthMode {
        case selection
        case login
        case signup
        case advanced
    }
    
    enum Field: Hashable {
        case username
        case pdsurl
        case appviewdid
        case chatdid
    }
    @FocusState private var focusedField: Field?

    // Logger
    private let logger = Logger(subsystem: "blue.catbird", category: "Auth")
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                /// Hyperrealistic clouds based on "Clouds" by drift
                /// https://www.shadertoy.com/view/4tdSWr
                /// Shader now renders the complete sky+clouds scene opaquely
                CloudView(
                    opacity: 1.0,          // Full opacity - shader handles complete scene
                    cloudScale: 1.1,       // Match original Shadertoy scale
                    animationSpeed: 1.0,   // Match original speed
                    shaderMode: .basic     // Use basic shader that matches original closest
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
                                .appFont(AppTextRole.headline)
                                .frame(maxWidth: min(geometry.size.width * 0.9, 400), alignment: .leading)
                                .padding(.bottom, 4)
                            
                            validatingTextFieldWithBackground(geometry: geometry)
                            
                            // Advanced AppView options toggle for login
                            Button {
                                withAnimation(.spring(duration: 0.4)) {
                                    showAppViewAdvancedOptions.toggle()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: showAppViewAdvancedOptions ? "chevron.down" : "chevron.right")
                                        .imageScale(.small)
                                    Text("Advanced Service Configuration")
                                        .appFont(AppTextRole.footnote)
                                }
                                .foregroundStyle(.secondary)
                            }
                            .padding(.top, 8)
                            
                            // Advanced AppView fields
                            if showAppViewAdvancedOptions {
                                appViewAdvancedFields(geometry: geometry)
                            }
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
                                    .appFont(AppTextRole.footnote)
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
                                Text(appStateManager.authentication.expiredAccountInfo != nil ? "Session Expired" : "Login Error")
                                    .appFont(AppTextRole.headline)
                                Spacer()
                                Button(action: {
                                    error = nil
                                    // Clear expired account info when dismissing error
                                    appStateManager.authentication.clearExpiredAccountInfo()
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .imageScale(.large)
                                }
                                .buttonStyle(.plain)
                            }

                            Text(appStateManager.authentication.expiredAccountInfo != nil ?
                                 "Your session for \(appStateManager.authentication.expiredAccountInfo?.handle ?? "this account") has expired." :
                                 errorMessage)
                                .appFont(AppTextRole.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button(appStateManager.authentication.expiredAccountInfo != nil ? "Sign In Again" : "Try Again") {
                                // Check if we have an expired account to re-authenticate
                                if let expiredAccount = appStateManager.authentication.expiredAccountInfo {
                                    // Automatically start OAuth flow for the expired account
                                    Task {
                                        await startReAuthenticationForExpiredAccount(expiredAccount)
                                    }
                                } else {
                                    // Reset error state and go back to selection
                                    error = nil
                                    appStateManager.authentication.resetError()
                                }
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 4)
                        }
                        .padding()
                        .frame(maxWidth: min(geometry.size.width * 0.9, 400))
                        .background(.quaternary)
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
                                    .appFont(AppTextRole.subheadline)
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
                        .background(Color.systemBackground.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            // Reset the cancelled state after 6 seconds
                            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                                withAnimation {
                                    self.authenticationCancelled = false
                                }
                            }
                        }
                    }
                    
                    Spacer(minLength: adaptiveSize(geometry, base: 40, min: 20))
                    
                    // Subtle credit for shader artist
                    HStack {
                        Spacer()
                        Text("Sky by drift")
                            .appFont(AppTextRole.caption2)
                            .foregroundStyle(.secondary.opacity(0.7))
                            .padding(.trailing, 8)
                            .padding(.bottom, 4)
                    }
                }
                .frame(minHeight: geometry.size.height)
                .padding(.horizontal)
            }
                .scrollBounceBehavior(.basedOnSize)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            }
        }
        .onChange(of: appStateManager.authentication.state) { _, newValue in
            // Update local error state based on auth manager errors
            if case .error(let message) = newValue {
                error = message
                isLoggingIn = false
                loginProgress = .idle
                showTimeoutCountdown = false
                // Cancel authentication task on error
                authenticationTask?.cancel()
                authenticationTask = nil
            } else if case .authenticated(let userDID) = newValue {
                // Successfully authenticated - transition to authenticated state
                Task {
                    await appStateManager.transitionToAuthenticated(userDID: userDID)
                }
                isLoggingIn = false
                loginProgress = .idle
                showTimeoutCountdown = false
                // Clear any cancelled state from previous attempts - we succeeded
                authenticationCancelled = false
                error = nil
                // Cancel authentication task on success
                authenticationTask?.cancel()
                authenticationTask = nil
            } else if case .authenticating(let progress) = newValue {
                // Update local progress based on detailed auth progress
                isLoggingIn = true
                showTimeoutCountdown = true

                // Map detailed progress to our local progress enum if needed
                switch progress {
                case .initializingClient, .resolvingHandle, .fetchingMetadata, .generatingAuthURL:
                    loginProgress = .startingAuth
                case .openingBrowser:
                    loginProgress = .authenticating
                case .waitingForCallback:
                    loginProgress = .authenticating
                case .exchangingTokens, .creatingSession:
                    loginProgress = .processingCallback
                case .finalizing:
                    loginProgress = .completing
                case .retrying:
                    // Keep current progress state during retries
                    break
                }
            }
        }
        .onDisappear {
            // Clean up authentication task when view disappears, but only if not actively authenticating
            // to avoid cancelling the task when ASWebAuthenticationSession opens a browser
            if !isLoggingIn {
                authenticationTask?.cancel()
                authenticationTask = nil
            }
            showTimeoutCountdown = false
            // Reset the re-authentication flag so it can trigger again if the user returns to this view
            hasStartedReAuthentication = false
        }
        .onTapGesture(count: 5) {
            // Hidden gesture: tap 5 times to enable debug mode
            showDebugInfo.toggle()
            let feedback = UINotificationFeedbackGenerator()
            feedback.notificationOccurred(.success)
        }
        .task {
            // Check biometric authentication availability
            biometricAuthAvailable = (appStateManager.authentication.biometricType != .none)

            // If there's an expired account, automatically start re-authentication
            // BUT: Skip this if we're explicitly adding a new account (not re-authenticating)
            // ALSO: Skip if already authenticating to prevent loops
            if let expiredAccount = appStateManager.authentication.expiredAccountInfo,
               !hasStartedReAuthentication,
               !isLoggingIn,
               !isAddingNewAccount,
               !appStateManager.authentication.state.isAuthenticating {
                logger.info("Expired account detected, automatically starting re-authentication")
                hasStartedReAuthentication = true
                await startReAuthenticationForExpiredAccount(expiredAccount)
            }
        }
        .onChange(of: appStateManager.authentication.expiredAccountInfo?.did) { oldValue, newValue in
            // React to expiredAccountInfo changes - trigger re-authentication when it's newly set
            // This handles the case where the user is logged out due to session expiry while using the app
            guard let newDID = newValue,
                  oldValue == nil, // Only trigger when newly set (nil -> value)
                  let expiredAccount = appStateManager.authentication.expiredAccountInfo,
                  !hasStartedReAuthentication,
                  !isLoggingIn,
                  !isAddingNewAccount,
                  !appStateManager.authentication.state.isAuthenticating else {
                return
            }
            
            logger.info("Expired account info changed (DID: \(newDID)), automatically starting re-authentication")
            hasStartedReAuthentication = true
            Task {
                await startReAuthenticationForExpiredAccount(expiredAccount)
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private func validatingTextFieldWithBackground(geometry: GeometryProxy) -> some View {
        return Group {
#if os(iOS)
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
#elseif os(macOS)
            ValidatingTextField(
                text: $handle,
                prompt: "username.bsky.social",
                icon: "at",
                validationError: validationError,
                isDisabled: isLoggingIn,
                submitLabel: .go,
                onSubmit: {
                    handleLogin()
                }
            )
#endif
        }
        .focused($focusedField, equals: Field.username)
        .shake(animatableParameter: showInvalidAnimation, appSettings: appStateManager.lifecycle.appState?.appSettings ?? AppSettings())
        .frame(maxWidth: min(geometry.size.width * 0.9, 400))
        .background(textFieldBackgroundView)
        .modifier(TextFieldShadowModifier(colorScheme: colorScheme))
        .overlay(textFieldOverlayView)
        .transition(AnyTransition.asymmetric(
            insertion: AnyTransition.scale(scale: 0.95).combined(with: AnyTransition.opacity),
            removal: AnyTransition.scale(scale: 1.05).combined(with: AnyTransition.opacity)
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
                    .appFont(AppTextRole.headline)
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
                    .appFont(AppTextRole.headline)
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
                .appFont(AppTextRole.headline)
                .frame(maxWidth: min(geometry.size.width * 0.9, 400), alignment: .leading)
            
            Group {
#if os(iOS)
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
#elseif os(macOS)
                ValidatingTextField(
                    text: $pdsURL,
                    prompt: "PDS URL (e.g., https://bsky.social)",
                    icon: "link",
                    validationError: validationError,
                    isDisabled: isLoggingIn,
                    submitLabel: .go,
                    onSubmit: {
                        handleAdvancedSignup()
                    }
                )
#endif
            }
            .focused($focusedField, equals: Field.pdsurl)
            .shake(animatableParameter: showInvalidAnimation, appSettings: appStateManager.lifecycle.appState?.appSettings ?? AppSettings())
            .frame(maxWidth: min(geometry.size.width * 0.9, 400))
            .transition(AnyTransition.opacity.combined(with: AnyTransition.move(edge: .top)))
        }
    }
    
    private func appViewAdvancedFields(geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure custom service endpoints")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: min(geometry.size.width * 0.9, 400), alignment: .leading)
            
            // AppView DID field
            VStack(alignment: .leading, spacing: 4) {
                Text("Bluesky AppView DID")
                    .appFont(AppTextRole.caption2)
                    .foregroundStyle(.secondary)
                
                Group {
#if os(iOS)
                    ValidatingTextField(
                        text: $customAppViewDID,
                        prompt: "did:web:api.bsky.app#bsky_appview",
                        icon: "server.rack",
                        validationError: nil,
                        isDisabled: isLoggingIn,
                        keyboardType: .URL,
                        submitLabel: .next,
                        onSubmit: {
                            focusedField = .chatdid
                        }
                    )
#elseif os(macOS)
                    ValidatingTextField(
                        text: $customAppViewDID,
                        prompt: "did:web:api.bsky.app#bsky_appview",
                        icon: "server.rack",
                        validationError: nil,
                        isDisabled: isLoggingIn,
                        submitLabel: .next,
                        onSubmit: {
                            focusedField = .chatdid
                        }
                    )
#endif
                }
                .focused($focusedField, equals: .appviewdid)
                .frame(maxWidth: min(geometry.size.width * 0.9, 400))
            }
            
            // Chat DID field
            VStack(alignment: .leading, spacing: 4) {
                Text("Bluesky Chat DID")
                    .appFont(AppTextRole.caption2)
                    .foregroundStyle(.secondary)
                
                Group {
#if os(iOS)
                    ValidatingTextField(
                        text: $customChatDID,
                        prompt: "did:web:api.bsky.chat#bsky_chat",
                        icon: "bubble.left.and.bubble.right",
                        validationError: nil,
                        isDisabled: isLoggingIn,
                        keyboardType: .URL,
                        submitLabel: .go,
                        onSubmit: {
                            handleLogin()
                        }
                    )
#elseif os(macOS)
                    ValidatingTextField(
                        text: $customChatDID,
                        prompt: "did:web:api.bsky.chat#bsky_chat",
                        icon: "bubble.left.and.bubble.right",
                        validationError: nil,
                        isDisabled: isLoggingIn,
                        submitLabel: .go,
                        onSubmit: {
                            handleLogin()
                        }
                    )
#endif
                }
                .focused($focusedField, equals: .chatdid)
                .frame(maxWidth: min(geometry.size.width * 0.9, 400))
            }
            
            // Reset to defaults button
            Button {
                withAnimation {
                    customAppViewDID = "did:web:api.bsky.app#bsky_appview"
                    customChatDID = "did:web:api.bsky.chat#bsky_chat"
                }
            } label: {
                Text("Reset to Defaults")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: min(geometry.size.width * 0.9, 400))
        .transition(.opacity.combined(with: .move(edge: .top)))
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
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(authModeActionText())
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.primary)
                    
                    Text(loginProgressDescription())
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    
                    // Show technical details in debug mode if available
                    if showDebugInfo, let technicalDescription = loginTechnicalDescription() {
                        Text(technicalDescription)
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
                
                Spacer()
                
                // Cancel button
                Button {
                    cancelAuthentication()
                } label: {
                    Text("Cancel")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            
            // Timeout countdown
            if showTimeoutCountdown {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.orange)
                        .imageScale(.small)
                    
                    Text("Timeout in \(timeoutCountdown)s")
                        .appFont(AppTextRole.caption2)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                }
            }
        }
        .frame(maxWidth: min(geometry.size.width * 0.9, 400))
        .padding()
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private func actionButton(geometry: GeometryProxy) -> some View {
        Button {
            handleActionButtonTap()
        } label: {
            Label {
                Text(authModeActionButtonText())
                    .appFont(AppTextRole.headline)
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
    
    /// Cancels the current authentication task
    private func cancelAuthentication() {
        logger.warning("User cancelled authentication")
        
        // Cancel the authentication task
        authenticationTask?.cancel()
        authenticationTask = nil
        
        // Reset state
        isLoggingIn = false
        loginProgress = .idle
        showTimeoutCountdown = false
        
        // Only show authenticationCancelled if user explicitly cancelled, not on errors
        // This prevents "Authentication cancelled" from appearing on auth failures
        authenticationCancelled = true

        // Reset the auth manager error state
        appStateManager.authentication.resetError()
    }
    
    /// Starts the timeout countdown
    private func startTimeoutCountdown() {
        showTimeoutCountdown = true
        timeoutCountdown = 60

        // Create a countdown timer
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] timer in

            DispatchQueue.main.async {
                if self.timeoutCountdown > 0 && self.isLoggingIn {
                    self.timeoutCountdown -= 1
                } else {
                    timer.invalidate()
                    self.showTimeoutCountdown = false
                }
            }
        }
    }
    
    private func authModeActionText() -> String {
        switch authMode {
        case .login:
            return "Signing In..."
        case .signup:
            return "Creating Account..."
        case .advanced:
            return "Connecting to PDS..."
        case .selection:
            return "" // Should never be used
        }
    }
    
    private func loginProgressDescription() -> String {
        // Check if we have detailed progress from auth manager
        if let authProgress = appStateManager.authentication.state.authProgress {
            return authProgress.userDescription
        }

        // Fallback to old progress descriptions
        switch loginProgress {
        case .idle:
            return ""
        case .startingAuth:
            return "Starting authentication flow"
        case .authenticating:
            return "Opening browser for secure login"
        case .processingCallback:
            return "Processing authentication"
        case .completing:
            return "Finalizing login"
        }
    }

    private func loginTechnicalDescription() -> String? {
        // Return technical description if available for debugging
        return appStateManager.authentication.state.authProgress?.technicalDescription
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
                self.showInvalidAnimation = false
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
                self.showInvalidAnimation = false
            }
            return false
        }
        
        // Clear validation error
        validationError = nil
        return true
    }
    
    private func startLogin() async {
        logger.info("Starting login for handle: \(handle)")
        
        // Cancel any existing authentication task
        authenticationTask?.cancel()
        
        // Update state
        isLoggingIn = true
        loginProgress = .startingAuth
        error = nil
        
        // Configure custom service DIDs if advanced options are enabled
        if showAppViewAdvancedOptions {
            appStateManager.authentication.customAppViewDID = customAppViewDID
            appStateManager.authentication.customChatDID = customChatDID
            logger.info("Using custom AppView DID: \(customAppViewDID)")
            logger.info("Using custom Chat DID: \(customChatDID)")
        }

        // Start timeout countdown
        startTimeoutCountdown()

        // Clean up handle - remove @ prefix and whitespace
        let cleanHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")

        // Create and store the authentication task
        authenticationTask = Task { @MainActor in
            do {
                // Get auth URL
                let authURL = try await appStateManager.authentication.login(handle: cleanHandle)
                
                // Check for cancellation after getting auth URL
                try Task.checkCancellation()
                
                // Update progress
                loginProgress = .authenticating
                
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

                    // Check for cancellation after web authentication
                    try Task.checkCancellation()
                    
                    logger.info("Authentication session completed successfully")

                    // Update progress
                    loginProgress = .processingCallback

                    // Process callback
                    try await appStateManager.authentication.handleCallback(callbackURL)

                    // Check for cancellation after callback processing
                    try Task.checkCancellation()

                    // Update progress
                    loginProgress = .completing

                    // Success is handled via onChange of authState

                } catch let authSessionError as ASWebAuthenticationSessionError {
                    // User cancelled authentication
                    logger.notice("Authentication was cancelled by user: \(authSessionError._nsError.localizedDescription)")
                    // Only set authenticationCancelled for explicit user cancellation
                    authenticationCancelled = true
                    isLoggingIn = false
                    loginProgress = .idle
                    showTimeoutCountdown = false
                    // Reset auth state to prevent getting stuck
                    appStateManager.authentication.resetError()
                } catch {
                    // Other authentication errors (including timeout)
                    logger.error("Authentication error: \(error.localizedDescription)")
                    // Don't show authenticationCancelled for errors, use error state instead
                    self.error = error.localizedDescription
                    authenticationCancelled = false
                    isLoggingIn = false
                    loginProgress = .idle
                    showTimeoutCountdown = false
                }
                
            } catch {
                // Error starting login flow (including timeout and cancellation)
                logger.error("Error starting login: \(error.localizedDescription)")
                
                // Check for specific cancellation errors
                let isCancellationError = error is CancellationError ||
                    (error as NSError).code == NSURLErrorCancelled ||
                    error.localizedDescription.contains("cancelled") ||
                    error.localizedDescription.contains("canceled")
                
                // Don't show cancellation errors as user-facing errors
                if !isCancellationError {
                    self.error = error.localizedDescription
                }
                
                isLoggingIn = false
                loginProgress = .idle
                showTimeoutCountdown = false
            }
            
            // Clean up the task reference
            authenticationTask = nil
        }
    }
    
    private func startReAuthenticationForExpiredAccount(_ expiredAccount: AuthenticationManager.AccountInfo) async {
        logger.info("Starting re-authentication for expired account: \(expiredAccount.handle ?? expiredAccount.did)")

        // Cancel any existing authentication task
        authenticationTask?.cancel()

        // Update state
        isLoggingIn = true
        loginProgress = .startingAuth
        error = nil

        // Start timeout countdown
        startTimeoutCountdown()

        // Create and store the authentication task
        authenticationTask = Task { @MainActor in
            do {
                // Get auth URL for the expired account
                let authURL = try await appStateManager.authentication.startOAuthFlowForExpiredAccount()

                guard let authURL else {
                    logger.error("Failed to get auth URL for expired account re-authentication")
                    error = "Failed to get authentication URL for expired account"
                    isLoggingIn = false
                    showTimeoutCountdown = false
                    hasStartedReAuthentication = false
                    return
                }

                // Check for cancellation after getting auth URL
                try Task.checkCancellation()

                // Update progress
                loginProgress = .authenticating

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

                    // Check for cancellation after web authentication
                    try Task.checkCancellation()

                    logger.info("Re-authentication session completed successfully")

                    // Update progress
                    loginProgress = .processingCallback

                    // Process callback
                    try await appStateManager.authentication.handleCallback(callbackURL)

                    // Check for cancellation after callback processing
                    try Task.checkCancellation()

                    // Update progress
                    loginProgress = .completing

                    // Success is handled via onChange of authState

                } catch let authSessionError as ASWebAuthenticationSessionError {
                    // User cancelled authentication
                    logger.notice("Re-authentication was cancelled by user: \(authSessionError._nsError.localizedDescription)")
                    // Only set authenticationCancelled for explicit user cancellation
                    authenticationCancelled = true
                    isLoggingIn = false
                    loginProgress = .idle
                    showTimeoutCountdown = false
                    hasStartedReAuthentication = false

                    // Clear expired account info to prevent automatic retry loop
                    await appStateManager.authentication.clearExpiredAccountInfo()

                    // Reset auth state to prevent getting stuck
                    appStateManager.authentication.resetError()
                } catch {
                    // Other authentication errors (including timeout)
                    logger.error("Re-authentication error: \(error.localizedDescription)")
                    // Don't show authenticationCancelled for errors, use error state instead
                    self.error = error.localizedDescription
                    authenticationCancelled = false
                    isLoggingIn = false
                    loginProgress = .idle
                    showTimeoutCountdown = false
                    hasStartedReAuthentication = false
                }

            } catch {
                // Error starting re-authentication flow (including timeout and cancellation)
                logger.error("Error starting re-authentication: \(error.localizedDescription)")

                // Check for specific cancellation errors
                let isCancellationError = error is CancellationError ||
                    (error as NSError).code == NSURLErrorCancelled ||
                    error.localizedDescription.contains("cancelled") ||
                    error.localizedDescription.contains("canceled")

                // Don't show cancellation errors as user-facing errors
                if !isCancellationError {
                    self.error = error.localizedDescription
                }

                isLoggingIn = false
                loginProgress = .idle
                showTimeoutCountdown = false
                hasStartedReAuthentication = false
            }

            // Clean up the task reference
            authenticationTask = nil
        }
    }

    private func startSignup(pdsURL: URL) async {
        logger.info("Starting signup with PDS URL: \(pdsURL.absoluteString)")
        
        // Cancel any existing authentication task
        authenticationTask?.cancel()
        
        // Update state
        isLoggingIn = true
        error = nil
        
        // Start timeout countdown
        startTimeoutCountdown()
        
        // Create and store the authentication task
        authenticationTask = Task { @MainActor in
            do {
                // Get auth URL for signup
                let authURL = try await appStateManager.authentication.client?.startSignUpFlow(pdsURL: pdsURL)

                // Check for cancellation after getting auth URL
                try Task.checkCancellation()

                guard let authURL else {
                    logger.error("Failed to get auth URL for signup")
                    error = "Failed to get authentication URL"
                    isLoggingIn = false
                    showTimeoutCountdown = false
                    return
                }

                // Open web authentication session
                do {
                    let callbackURL = try await webAuthenticationSession.authenticate(
                        using: authURL,
                        callback: .https(host: "catbird.blue", path: "/oauth/callback"),
                        preferredBrowserSession: .shared, additionalHeaderFields: [:]
                    )

                    // Check for cancellation after web authentication
                    try Task.checkCancellation()

                    logger.info("Signup authentication session completed successfully")

                    // Process callback
                    try await appStateManager.authentication.handleCallback(callbackURL)

                    // Check for cancellation after callback processing
                    try Task.checkCancellation()

                    // Success is handled via onChange of authState

                } catch let authSessionError as ASWebAuthenticationSessionError {
                    // User cancelled authentication
                    logger.notice("Signup was cancelled by user: \(authSessionError._nsError.localizedDescription)")
                    // Only set authenticationCancelled for explicit user cancellation
                    authenticationCancelled = true
                    isLoggingIn = false
                    showTimeoutCountdown = false
                    // Reset auth state to prevent getting stuck
                    appStateManager.authentication.resetError()
                } catch {
                    // Other authentication errors (including timeout)
                    logger.error("Signup authentication error: \(error.localizedDescription)")
                    
                    // Don't show authenticationCancelled for errors, use error state instead
                    self.error = error.localizedDescription
                    authenticationCancelled = false
                    isLoggingIn = false
                    showTimeoutCountdown = false
                }
                
            } catch {
                // Error starting signup flow (including timeout and cancellation)
                logger.error("Error starting signup: \(error.localizedDescription)")
                
                // Check for specific cancellation errors
                let isCancellationError = error is CancellationError ||
                    (error as NSError).code == NSURLErrorCancelled ||
                    error.localizedDescription.contains("cancelled") ||
                    error.localizedDescription.contains("canceled")
                
                // Don't show cancellation errors as user-facing errors
                if !isCancellationError {
                    self.error = error.localizedDescription
                }
                
                isLoggingIn = false
                showTimeoutCountdown = false
            }
            
            // Clean up the task reference
            authenticationTask = nil
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
    @Previewable @Environment(AppState.self) var appState
    // Preview provider for LoginView
    
    LoginView()
        .applyAppStateEnvironment(appState)
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
