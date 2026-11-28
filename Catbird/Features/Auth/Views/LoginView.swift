import AuthenticationServices
import OSLog
import Petrel
import SwiftUI

/// Source-account recovery must not finish a different account's sign-in.
enum LoginAuthenticationCompletionPolicy {
    nonisolated static func accepts(_ state: AuthState, reauthenticationDID: String?) -> Bool {
        guard case .authenticated(let did) = state else { return false }
        return reauthenticationDID == nil || did == reauthenticationDID
    }
}

struct LoginView: View {
    // MARK: - Properties
    /// Indicates if this LoginView is being used to add a new account (vs initial login or re-authentication)
    let isAddingNewAccount: Bool
    /// Shows a Cancel button when presented as a sheet, so there's an explicit way out.
    let isPresentedModally: Bool
    
    // MARK: - Environment
    @Environment(AppStateManager.self) private var appStateManager
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.skyAnimationPaused) private var skyAnimationPaused
    @Environment(\.dismiss) private var dismiss

    /// Shared static fallback so text field shake animations do not allocate a new
    /// AppSettings model and observers on every keystroke when signed out.
    @MainActor static let signedOutFallback = AppSettings()
    // MARK: - Initialization
    init(isAddingNewAccount: Bool = false, initialAuthMode: AuthMode = .selection, isPresentedModally: Bool = false) {
        self.isAddingNewAccount = isAddingNewAccount
        self.isPresentedModally = isPresentedModally
        self._authMode = State(initialValue: initialAuthMode)
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
    @State private var showSavedAccounts = false
    @State private var authModeAwaitingAgreement: AuthMode?
    @AppStorage(CommunityStandards.acceptedAgreementVersionKey) private var acceptedAgreementVersion = 0
    
    // Advanced AppView configuration
    @State private var customAppViewDID = "did:web:api.bsky.app#bsky_appview"
    @State private var customChatDID = "did:web:api.bsky.chat#bsky_chat"
    @State private var showAppViewAdvancedOptions = false
    
    // Task cancellation support
    @State private var authenticationTask: Task<Void, Never>?
    // Track if we've already started re-authentication to prevent multiple OAuth prompts
    @State private var hasStartedReAuthentication = false
    // Capture the intended account independently of mutable global expiry state.
    @State private var reauthenticationTargetDID: String?
    
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
                SkyView(animated: !reduceMotion && scenePhase == .active && !isLoggingIn && !showSavedAccounts && !skyAnimationPaused && (isPresentedModally || StarterPackOnboardingManager.shared.activeFlowID == nil))
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
                legalFooterScrim

                // Main content scroll view
                ScrollView {
                    VStack(spacing: adaptiveSpacing(geometry)) {
                    // Logo/Header Area
                    ZStack(alignment: .topLeading) {
                        // Center logo and text
                        VStack(spacing: adaptiveSpacing(geometry, factor: 0.4)) {
                            // Live 3D mascot: drag to spin, tap to bounce.
                            BirdSpinner(size: adaptiveSize(geometry, base: 250, min: 120))
                                .accessibilityHidden(true)
                                .padding(.bottom, adaptiveSpacing(geometry, factor: 0.2))
                            
                            VStack(spacing: 3) {
                                Text(verbatim: "Catbird")
                                    .font(catbirdTitleFont(geometry: geometry))
                                    .foregroundStyle(.primary)
                                
                                Text("for Bluesky", comment: "Subtitle below the Catbird brand title on the sign-in screen.")
                                    .font(catbirdSubtitleFont(geometry: geometry))
                                    // Vibrant .secondary turns muddy over the sky.
                                    .foregroundStyle(.primary.opacity(0.7))
                            }
                        }
                        .frame(maxWidth: .infinity) // Center the VStack
                    }
                    .padding(.top, adaptiveSpacing(geometry, factor: 0.2))
                    .padding(.bottom, adaptiveSpacing(geometry, factor: 0.3))
                    
                    // Authentication Options
                    VStack(spacing: adaptiveSpacing(geometry, factor: 0.7)) {
                        if let pendingContext = StarterPackOnboardingManager.shared.pendingContext {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(Color.accentColor)
                                Group {
                                    if let packName = pendingContext.name, !packName.isEmpty {
                                        Text("Joining \(packName)", comment: "Banner on sign-in screen when joining via a named starter pack. Placeholder is the starter pack name.")
                                    } else {
                                        Text("Joining Starter Pack", comment: "Banner on sign-in screen when joining via an unnamed starter pack.")
                                    }
                                }
                                    .appFont(AppTextRole.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .padding(.bottom, 4)
                        }

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
                            
                            #if DEBUG
                            // Advanced AppView options toggle for login (developer builds only)
                            Button {
                                withAnimation(navigationAnimation) {
                                    showAppViewAdvancedOptions.toggle()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: showAppViewAdvancedOptions ? "chevron.down" : "chevron.forward")
                                        .imageScale(.small)
                                    Text(verbatim: "Advanced Service Configuration")
                                        .appFont(AppTextRole.footnote)
                                }
                                .foregroundStyle(.secondary)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .disabled(isLoggingIn)
                            .padding(.top, 8)
                            
                            // Advanced AppView fields
                            if showAppViewAdvancedOptions {
                                appViewAdvancedFields(geometry: geometry)
                            }
                            #endif
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
                                withAnimation(navigationAnimation) {
                                    showAdvancedOptions.toggle()
                                    authMode = showAdvancedOptions ? .advanced : .signup
                                    if showAdvancedOptions {
                                        focusedField = .pdsurl
                                    }
                                }
                            } label: {
                                Text(showAdvancedOptions ? "Use Bluesky Instead" : "Use Another Provider")
                                    .appFont(AppTextRole.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .disabled(isLoggingIn)
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
                                    .symbolEffect(.pulse, isActive: !reduceMotion)
                                Text(appStateManager.authentication.expiredAccountInfo != nil ? "Session Expired" : "Couldn’t Sign In")
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
                                .accessibilityLabel("Dismiss Error")
                            }

                            Group {
                                if let expiredAccount = appStateManager.authentication.expiredAccountInfo {
                                    if let loginHandle = expiredAccount.loginHandle, !loginHandle.isEmpty {
                                        Text("Your session for \(loginHandle) has expired.", comment: "Message shown when a saved account's session expired. Placeholder is the account handle.")
                                    } else {
                                        Text("Your session for this account has expired.", comment: "Message shown when a saved account's session expired and no handle is available.")
                                    }
                                } else {
                                    Text(errorMessage)
                                }
                            }
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
                            .buttonStyle(.catbird(.tonal, size: .md))
                            .padding(.top, 4)
                        }
                        .padding()
                        .frame(maxWidth: min(geometry.size.width * 0.9, 400))
                        .catbirdCard(.panel)
                        .padding(.horizontal)
                    }
                    
                    // Auth cancelled toast with option to go back
                    if authenticationCancelled {
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                Text("Sign-in canceled")
                                    .appFont(AppTextRole.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Button(action: returnToSignInOptions) {
                                Text("Back to Sign-In Options")
                                    .frame(minHeight: 44)
                            }
                            .modifier(SecondaryAuthButtonModifier())
                            .disabled(isLoggingIn)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color.systemBackground.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.1), radius: 1, x: 0, y: 1)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            // Reset the cancelled state after 6 seconds
                            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                                withAnimation(reduceMotion ? nil : .default) {
                                    self.authenticationCancelled = false
                                }
                            }
                        }
                    }
                    
                    Spacer(minLength: adaptiveSize(geometry, base: 40, min: 20))
                    legalFooter
                    
                }
                .frame(minHeight: geometry.size.height)
                .padding(.horizontal)
            }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .toolbar { loginToolbar }
        .modifier(LoginNavigationContainer())
        .modifier(LoginSheetFrame(isPresentedModally: isPresentedModally))
        .sheet(isPresented: $showSavedAccounts) {
            AccountSwitcherView()
                .environment(appStateManager)
        }
        .sheet(isPresented: isShowingAgreement) {
            CommunityStandardsAgreementView(
                onAgree: {
                    CommunityStandards.recordAcceptanceBeforeSignIn()
                    let mode = authModeAwaitingAgreement
                    authModeAwaitingAgreement = nil
                    if let mode {
                        enterAuthMode(mode)
                    }
                },
                onCancel: { authModeAwaitingAgreement = nil }
            )
        }
        .onChange(of: appStateManager.authentication.state) { _, newValue in
            // Update local error state based on auth manager errors
            if case .error(let message) = newValue {
                error = message
                isLoggingIn = false
                loginProgress = .idle
                // Cancel authentication task on error
                authenticationTask?.cancel()
                authenticationTask = nil
            } else if case .authenticated = newValue {
                guard LoginAuthenticationCompletionPolicy.accepts(
                    newValue, reauthenticationDID: reauthenticationTargetDID
                ) else { return }
                // Centralized auth state observation in AppStateManager handles transitionToAuthenticated and error recovery.
                isLoggingIn = false
                loginProgress = .idle
                // Clear any cancelled state from previous attempts - we succeeded
                authenticationCancelled = false
                error = nil
                // Cancel authentication task on success
                authenticationTask?.cancel()
                authenticationTask = nil
            } else if case .authenticating(let progress) = newValue {
                // Update local progress based on detailed auth progress
                isLoggingIn = true

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
            // Reset the re-authentication flag so it can trigger again if the user returns to this view
            hasStartedReAuthentication = false
        }
        .modifier(DebugInfoTapGesture(showDebugInfo: $showDebugInfo))
        .task {
            // Entry points that open straight into sign-in or sign-up still ask for the
            // Community Standards agreement first.
            if authMode != .selection,
               acceptedAgreementVersion < CommunityStandards.agreementVersion {
                authModeAwaitingAgreement = authMode
                authMode = .selection
            }

            // Check biometric authentication availability
            biometricAuthAvailable = (appStateManager.authentication.biometricType != .none)

            // Load saved accounts so the Saved Accounts button reflects what the switcher can show.
            if !isAddingNewAccount {
                await appStateManager.authentication.refreshAvailableAccounts()
            }

            // If there's an expired account, automatically start re-authentication
            // BUT: Skip this if we're explicitly adding a new account (not re-authenticating)
            // ALSO: Skip if already authenticating to prevent loops
            if let expiredAccount = appStateManager.authentication.expiredAccountInfo,
               !hasStartedReAuthentication,
               !isLoggingIn,
               !isAddingNewAccount,
               !appStateManager.authentication.state.isAuthenticating {
                guard let loginHandle = expiredAccount.loginHandle else {
                    logger.warning("Expired account has no saved handle; waiting for manual username entry")
                    focusedField = .username
                    return
                }
                
                logger.info("Expired account detected, automatically starting re-authentication")
                handle = loginHandle
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
            
            guard let loginHandle = expiredAccount.loginHandle else {
                logger.warning("Expired account info changed for DID \(newDID), but no saved handle is available")
                focusedField = .username
                return
            }
            
            logger.info("Expired account info changed (DID: \(newDID)), automatically starting re-authentication")
            handle = loginHandle
            hasStartedReAuthentication = true
            Task {
                await startReAuthenticationForExpiredAccount(expiredAccount)
            }
        }
    }
    
    // MARK: - Navigation

    private var navigationAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.4)
    }

    @ToolbarContentBuilder
    private var loginToolbar: some ToolbarContent {
        if authMode != .selection {
            ToolbarItem(placement: .navigation) {
                Button(action: returnToSignInOptions) {
                    Label("Back", systemImage: "chevron.backward")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(isLoggingIn)
                .accessibilityIdentifier("login.back")
            }
        }
        if isPresentedModally {
            ToolbarItem(placement: modalCancelPlacement) {
                Button(action: cancelAndDismiss) {
                    Text("Cancel")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("login.cancel")
            }
        }
    }

    private var modalCancelPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .cancellationAction
        #endif
    }

    private func returnToSignInOptions() {
        guard !isLoggingIn else { return }
        focusedField = nil
        withAnimation(navigationAnimation) {
            authMode = .selection
            showAdvancedOptions = false
            showAppViewAdvancedOptions = false
            error = nil
            validationError = nil
            authenticationCancelled = false
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
                label: String(localized: "Handle", comment: "Text field label for the user's Bluesky handle on the sign-in screen."),
                validationError: validationError,
                isDisabled: isLoggingIn,
                keyboardType: .emailAddress,
                textContentType: .username,
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
                label: String(localized: "Handle", comment: "Text field label for the user's Bluesky handle on the sign-in screen."),
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
        .shake(animatableParameter: showInvalidAnimation, appSettings: appStateManager.lifecycle.appState?.appSettings ?? LoginView.signedOutFallback)
        .frame(maxWidth: min(geometry.size.width * 0.9, 400))
        .transition(AnyTransition.asymmetric(
            insertion: AnyTransition.scale(scale: 0.95).combined(with: AnyTransition.opacity),
            removal: AnyTransition.scale(scale: 1.05).combined(with: AnyTransition.opacity)
        ))
    }
    
    @ViewBuilder
    private var authSelectionButtons: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 16) {
                authSelectionButtonContent
            }
        } else {
            authSelectionButtonContent
        }
    }

    private var authSelectionButtonContent: some View {
        VStack(spacing: 16) {
            // Login Button
            Button {
                guard authMode == .selection, !isLoggingIn else { return }
                enterAuthModeAfterAgreement(.login)
            } label: {
                Text("Sign In", comment: "Primary button to begin signing in to an existing Bluesky account.")
            }
            .modifier(PrimaryButtonModifier())
            .accessibilityIdentifier("login.signIn")
            
            // Sign Up Button
            Button {
                guard authMode == .selection, !isLoggingIn else { return }
                enterAuthModeAfterAgreement(.signup)
            } label: {
                Text("Create Account")
            }
            .modifier(PrimaryButtonModifier())
            .accessibilityIdentifier("login.createAccount")
            
            // Only offer Saved Accounts when the switcher has accounts to show.
            if !isAddingNewAccount && !appStateManager.authentication.availableAccounts.isEmpty {
                Button { showSavedAccounts = true } label: {
                    Text("Saved Accounts")
                        .appFont(AppTextRole.subheadline)
                        .frame(maxWidth: .infinity, minHeight: ControlHeight.lg)
                }
                .modifier(SecondaryAuthButtonModifier())
                .disabled(isLoggingIn || appStateManager.authentication.state.isAuthenticating)
                .accessibilityIdentifier("login.savedAccounts")
            }
        }
        .disabled(isLoggingIn)
    }

    private var legalFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { legalLinks }
            VStack(spacing: 0) { legalLinks }
        }
        .appFont(AppTextRole.footnote)
        .multilineTextAlignment(.center)
        // The links sit on the animated sky, which can drift a white cloud behind
        // them; white text over `legalFooterScrim` reads on clouds and deep blue.
        .tint(.white)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
        .padding(.bottom, 8)
    }

    /// Darkens the bottom of the sky, behind the legal links.
    private var legalFooterScrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.16), location: 0.45),
                .init(color: .black.opacity(0.42), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 200)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var legalLinks: some View {
        Link("Terms of Service", destination: CommunityStandards.termsOfServiceURL)
            .frame(minHeight: 44)
            .accessibilityIdentifier("login.terms")
        if let privacyURL = LegalConfig.privacyPolicyURL {
            Link("Privacy Policy", destination: privacyURL)
                .frame(minHeight: 44)
                .accessibilityIdentifier("login.privacy")
        }
        Link("Community Guidelines", destination: CommunityStandards.communityGuidelinesURL)
            .frame(minHeight: 44)
            .accessibilityIdentifier("login.communityGuidelines")
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
    
    
    private func advancedPDSField(geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Create an account with another provider")
                .appFont(AppTextRole.headline)
                .frame(maxWidth: min(geometry.size.width * 0.9, 400), alignment: .leading)
            
            Group {
#if os(iOS)
                ValidatingTextField(
                    text: $pdsURL,
                    prompt: String(localized: "Provider address, like https://bsky.social", comment: "Placeholder in custom PDS server address text field."),
                    icon: "link",
                    label: String(localized: "Server Address", comment: "Accessibility label for custom PDS server address text field."),
                    validationError: validationError,
                    isDisabled: isLoggingIn,
                    keyboardType: .URL,
                    textContentType: .URL,
                    submitLabel: .go,
                    onSubmit: {
                        handleAdvancedSignup()
                    }
                )
#elseif os(macOS)
                ValidatingTextField(
                    text: $pdsURL,
                    prompt: String(localized: "Provider address, like https://bsky.social", comment: "Placeholder in custom PDS server address text field."),
                    icon: "link",
                    label: String(localized: "Server Address", comment: "Accessibility label for custom PDS server address text field."),
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
            .shake(animatableParameter: showInvalidAnimation, appSettings: appStateManager.lifecycle.appState?.appSettings ?? LoginView.signedOutFallback)
            .frame(maxWidth: min(geometry.size.width * 0.9, 400))
            .transition(AnyTransition.opacity.combined(with: AnyTransition.move(edge: .top)))
        }
    }
    
    private func appViewAdvancedFields(geometry: GeometryProxy) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "Configure custom service endpoints")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: min(geometry.size.width * 0.9, 400), alignment: .leading)
            
            // AppView DID field
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "Bluesky AppView DID")
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
                Text(verbatim: "Bluesky Chat DID")
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
                withAnimation(reduceMotion ? nil : .default) {
                    customAppViewDID = "did:web:api.bsky.app#bsky_appview"
                    customChatDID = "did:web:api.bsky.chat#bsky_chat"
                }
            } label: {
                Text(verbatim: "Reset to Defaults")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .catbirdCard(.panel)
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
                        Text(verbatim: technicalDescription)
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
                        .padding(.horizontal, 12)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .modifier(SecondaryAuthButtonModifier())
                .accessibilityIdentifier("login.cancelAuthentication")
            }
        }
        .frame(maxWidth: min(geometry.size.width * 0.9, 400))
        .padding()
        .catbirdCard(.panel)
    }
    
    private func actionButton(geometry: GeometryProxy) -> some View {
        Button {
            handleActionButtonTap()
        } label: {
            Label {
                Text(authModeActionButtonText())
            } icon: {
                Image(systemName: authModeActionIcon())
            }
        }
        .modifier(PrimaryButtonModifier())
        .frame(maxWidth: min(geometry.size.width * 0.9, 400))
        .disabled(isButtonDisabled() || isLoggingIn)
        .accessibilityIdentifier("login.continue")
    }
    
    private var isShowingAgreement: Binding<Bool> {
        Binding(
            get: { authModeAwaitingAgreement != nil },
            set: { if !$0 { authModeAwaitingAgreement = nil } }
        )
    }

    /// Signing in and creating an account both require the current Community Standards
    /// agreement; it is asked for once per agreement version on this device.
    private func enterAuthModeAfterAgreement(_ mode: AuthMode) {
        if acceptedAgreementVersion >= CommunityStandards.agreementVersion {
            enterAuthMode(mode)
        } else {
            authModeAwaitingAgreement = mode
        }
    }

    private func enterAuthMode(_ mode: AuthMode) {
        withAnimation(navigationAnimation) {
            authMode = mode
            if mode == .login {
                focusedField = .username
            }
        }
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
        
        // Cancel the authentication task and invalidate any prepared exchange attempt.
        cancelAuthenticationTaskAndPendingAttempt()
        
        // Reset state
        isLoggingIn = false
        loginProgress = .idle
        // Only show authenticationCancelled if user explicitly cancelled, not on errors
        // This prevents "Authentication cancelled" from appearing on auth failures
        authenticationCancelled = true

        // Reset the auth manager error state
        appStateManager.authentication.resetError()
    }
    
    /// Stops any sign-in in progress and closes the sheet.
    private func cancelAndDismiss() {
        if isLoggingIn {
            cancelAuthenticationTaskAndPendingAttempt()
            isLoggingIn = false
            loginProgress = .idle
            appStateManager.authentication.resetError()
        }
        dismiss()
    }
    
    private func authModeActionText() -> String {
        switch authMode {
        case .login:
            return String(localized: "Signing in…", comment: "Status label shown while signing in to an account.")
        case .signup:
            return String(localized: "Creating account…", comment: "Status label shown while creating a new account.")
        case .advanced:
            return String(localized: "Connecting to your provider…", comment: "Status label shown while connecting to a custom PDS provider.")
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
            return String(localized: "Starting sign-in", comment: "Progress step when preparing sign-in.")
        case .authenticating:
            return String(localized: "Opening a secure sign-in page", comment: "Progress step when opening OAuth browser page.")
        case .processingCallback:
            return String(localized: "Finishing sign-in", comment: "Progress step when completing OAuth callback.")
        case .completing:
            return String(localized: "Almost done", comment: "Progress step when sign-in is nearly complete.")
        }
    }

    private func loginTechnicalDescription() -> String? {
        // Return technical description if available for debugging
        return appStateManager.authentication.state.authProgress?.technicalDescription
    }
    
    private func authModeActionButtonText() -> String {
        switch authMode {
        case .login:
            return String(localized: "Sign In", comment: "Action button to submit handle and sign in.")
        case .signup:
            return String(localized: "Create Account on Bluesky", comment: "Action button to create a new account on the default Bluesky server.")
        case .advanced:
            return String(localized: "Create Account", comment: "Action button to create a new account on a custom provider.")
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
        guard !isLoggingIn else { return }
        // Validate handle format
        guard validateHandle(handle) else {
            return
        }
        
        // Reserve the UI and store the cancellable task before accepting another tap.
        startLogin()
    }
    
    private func handleSignup() {
        guard !isLoggingIn else { return }
        // Start signup process with default PDS URL (bsky.social)
        startSignup(pdsURL: URL(string: "https://bsky.social")!)
    }
    
    private func handleAdvancedSignup() {
        guard !isLoggingIn else { return }
        // Validate PDS URL
        guard let url = URL(string: pdsURL), isValidURL(pdsURL) else {
            validationError = String(
                localized: "Enter a full web address, like https://example.com.",
                comment: "Validation error when custom PDS URL is malformed."
            )
            showInvalidAnimation = true
            // Reset animation flag after a delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.showInvalidAnimation = false
            }
            return
        }
        
        // Start signup process with custom PDS URL
        startSignup(pdsURL: url)
    }
    
    private func validateHandle(_ handle: String) -> Bool {
        let trimmedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Simple validation - must contain a dot or @ symbol
        guard trimmedHandle.contains(".") || trimmedHandle.contains("@") else {
            logger.warning("Invalid handle format: \(trimmedHandle)")
            validationError = String(
                localized: "Enter your full handle, like name.bsky.social.",
                comment: "Validation error when handle does not include a domain."
            )
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
    
    private func startLogin() {
        logger.info("Starting login for handle: \(handle)")
        reauthenticationTargetDID = nil
        
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
                          preferredBrowserSession: .ephemeral,
                          additionalHeaderFields: [:]
                        )
                    } else {
                        // Fallback on earlier versions
                        callbackURL = try await webAuthenticationSession.authenticate(using: URL(string: "https://catbird/oauth/callback")!, callbackURLScheme: "catbird", preferredBrowserSession: .ephemeral
                          )
                    }

                    // Check for cancellation after web authentication
                    try Task.checkCancellation()
                    
                    logger.info("Authentication session completed successfully")

                    // Update progress
                    loginProgress = .processingCallback

                    // Process callback
                    try await appStateManager.authentication.handleGatewayCallback(callbackURL)

                    // Check for cancellation after callback processing
                    try Task.checkCancellation()

                    // Update progress
                    loginProgress = .completing

                    // Success is handled via onChange of authState

                } catch let authSessionError as ASWebAuthenticationSessionError {
                    await appStateManager.authentication.cancelGatewayOAuthFlow()
                    // User cancelled authentication
                    logger.notice("Authentication was cancelled by user: \(authSessionError._nsError.localizedDescription)")
                    // Only set authenticationCancelled for explicit user cancellation
                    authenticationCancelled = true
                    isLoggingIn = false
                    loginProgress = .idle
                    // Reset auth state to prevent getting stuck
                    appStateManager.authentication.resetError()
                } catch is CancellationError {
                    // Task was cancelled (e.g., auth state changed to authenticated
                    // before this task finished cleanup) — not a real error
                    logger.notice("Authentication task cancelled (auth may have already succeeded)")
                    isLoggingIn = false
                    loginProgress = .idle
                } catch {
                    // Other authentication errors (including timeout)
                    logger.error("Authentication error: \(error.localizedDescription)")
                    // Don't show authenticationCancelled for errors, use error state instead
                    self.error = AuthenticationManager.userFacingMessage(for: error)
                    authenticationCancelled = false
                    isLoggingIn = false
                    loginProgress = .idle
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
                    self.error = AuthenticationManager.userFacingMessage(for: error)
                }
                
                isLoggingIn = false
                loginProgress = .idle
            }
            
            // Clean up the task reference
            authenticationTask = nil
        }
    }
    
    private func startReAuthenticationForExpiredAccount(_ expiredAccount: AuthenticationManager.AccountInfo) async {
        reauthenticationTargetDID = expiredAccount.did
        guard expiredAccount.loginHandle != nil else {
            logger.warning("Cannot automatically re-authenticate expired account without a saved handle")
            focusedField = .username
            hasStartedReAuthentication = false
            isLoggingIn = false
            loginProgress = .idle
            return
        }

        logger.info("Starting re-authentication for expired account: \(expiredAccount.loginHandle ?? expiredAccount.did)")

        // Cancel any existing authentication task
        authenticationTask?.cancel()

        // Update state
        isLoggingIn = true
        loginProgress = .startingAuth
        error = nil


        // Create and store the authentication task
        authenticationTask = Task { @MainActor in
            do {
                // Get auth URL for the expired account
                let authURL = try await appStateManager.authentication.startOAuthFlowForExpiredAccount()

                guard let authURL else {
                    logger.error("Failed to get auth URL for expired account re-authentication")
                    error = String(
                        localized: "Couldn’t start signing in. Try again.",
                        comment: "Error shown when re-authentication URL cannot be created."
                    )
                    isLoggingIn = false
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
                          preferredBrowserSession: .ephemeral,
                          additionalHeaderFields: [:]
                        )
                    } else {
                        // Fallback on earlier versions
                        callbackURL = try await webAuthenticationSession.authenticate(using: URL(string: "https://catbird/oauth/callback")!, callbackURLScheme: "catbird", preferredBrowserSession: .ephemeral
                          )
                    }

                    // Check for cancellation after web authentication
                    try Task.checkCancellation()

                    logger.info("Re-authentication session completed successfully")

                    // Update progress
                    loginProgress = .processingCallback

                    // Process callback
                    try await appStateManager.authentication.handleGatewayCallback(callbackURL)

                    // Check for cancellation after callback processing
                    try Task.checkCancellation()

                    // Update progress
                    loginProgress = .completing

                    // Success is handled via onChange of authState

                } catch let authSessionError as ASWebAuthenticationSessionError {
                    await appStateManager.authentication.cancelGatewayOAuthFlow()
                    // User cancelled authentication
                    logger.notice("Re-authentication was cancelled by user: \(authSessionError._nsError.localizedDescription)")
                    // Only set authenticationCancelled for explicit user cancellation
                    authenticationCancelled = true
                    isLoggingIn = false
                    loginProgress = .idle
                    hasStartedReAuthentication = false

                    // Clear expired account info to prevent automatic retry loop
                    await appStateManager.authentication.clearExpiredAccountInfo()

                    // Reset auth state to prevent getting stuck
                    appStateManager.authentication.resetError()
                } catch {
                    // Other authentication errors (including timeout)
                    logger.error("Re-authentication error: \(error.localizedDescription)")
                    // Don't show authenticationCancelled for errors, use error state instead
                    self.error = AuthenticationManager.userFacingMessage(for: error)
                    authenticationCancelled = false
                    isLoggingIn = false
                    loginProgress = .idle
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
                    self.error = AuthenticationManager.userFacingMessage(for: error)
                }

                isLoggingIn = false
                loginProgress = .idle
                hasStartedReAuthentication = false
            }

            // Clean up the task reference
            authenticationTask = nil
        }
    }

    private func startSignup(pdsURL: URL) {
        logger.info("Starting signup with PDS URL: \(pdsURL.absoluteString)")
        reauthenticationTargetDID = nil
        // New accounts get the welcome flow once they're signed in; existing accounts don't.
        NewAccountOnboardingMarker.markSignupStarted()
        
        // Cancel any existing authentication task
        authenticationTask?.cancel()
        
        // Update state
        isLoggingIn = true
        error = nil
        
        
        // Create and store the authentication task
        authenticationTask = Task { @MainActor in
            do {
                // Get auth URL for signup
                let authURL = try await appStateManager.authentication.startSignUp(pdsURL: pdsURL)

                // Check for cancellation after getting auth URL
                try Task.checkCancellation()

                // Open web authentication session
                do {
                    let callbackURL = try await webAuthenticationSession.authenticate(
                        using: authURL,
                        callback: .https(host: "catbird.blue", path: "/oauth/callback"),
                        preferredBrowserSession: .ephemeral, additionalHeaderFields: [:]
                    )

                    // Check for cancellation after web authentication
                    try Task.checkCancellation()

                    logger.info("Signup authentication session completed successfully")

                    // Process callback
                    try await appStateManager.authentication.handleGatewayCallback(callbackURL)

                    // Check for cancellation after callback processing
                    try Task.checkCancellation()

                    // Success is handled via onChange of authState

                } catch let authSessionError as ASWebAuthenticationSessionError {
                    await appStateManager.authentication.cancelGatewayOAuthFlow()
                    // User cancelled authentication
                    logger.notice("Signup was cancelled by user: \(authSessionError._nsError.localizedDescription)")
                    // Only set authenticationCancelled for explicit user cancellation
                    authenticationCancelled = true
                    isLoggingIn = false
                    // Reset auth state to prevent getting stuck
                    appStateManager.authentication.resetError()
                } catch {
                    // Other authentication errors (including timeout)
                    logger.error("Signup authentication error: \(error.localizedDescription)")
                    
                    // Don't show authenticationCancelled for errors, use error state instead
                    self.error = AuthenticationManager.userFacingMessage(for: error)
                    authenticationCancelled = false
                    isLoggingIn = false
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
                    self.error = AuthenticationManager.userFacingMessage(for: error)
                }
                
                isLoggingIn = false
            }
            
            // Clean up the task reference
            authenticationTask = nil
        }
    }

    private func cancelPendingAttemptBeforeCallback() async {
        await appStateManager.authentication.cancelGatewayOAuthFlow()
    }

    private func cancelAuthenticationTaskAndPendingAttempt() {
        authenticationTask?.cancel()
        authenticationTask = nil
        Task { @MainActor in
            await cancelPendingAttemptBeforeCallback()
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
  AsyncPreviewContent { _ in
    // Preview provider for LoginView
    
        LoginView()
  }
}

// MARK: - View Modifiers

/// Developer builds only: tapping the sign-in background five times shows technical sign-in progress.
private struct DebugInfoTapGesture: ViewModifier {
    @Binding var showDebugInfo: Bool
    
    func body(content: Content) -> some View {
        #if DEBUG
        content.onTapGesture(count: 5) {
            showDebugInfo.toggle()
            PlatformHaptics.success()
        }
        #else
        content
        #endif
    }
}

/// Login is presented directly at the signed-out root and in account/starter-pack sheets.
private struct LoginNavigationContainer: ViewModifier {
    func body(content: Content) -> some View {
        NavigationStack {
            #if os(iOS)
            content.navigationBarTitleDisplayMode(.inline)
            #else
            content
            #endif
        }
    }
}

/// macOS sheets size to their content's ideal size, and the sign-in screen is a
/// `GeometryReader`, which has none, so a modal sign-in sheet would collapse.
/// Give it an explicit size there; the full-window sign-in screen and iOS are unchanged.
private struct LoginSheetFrame: ViewModifier {
    let isPresentedModally: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        if isPresentedModally {
            content.frame(minWidth: 480, idealWidth: 540, minHeight: 600, idealHeight: 680)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Secondary action on the sign-in screen. Glass keeps the label legible over
/// both the sky's clouds and its deep blue, where a tinted bordered style
/// renders blue-on-blue and reads as disabled.
struct SecondaryAuthButtonModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .buttonStyle(.borderedProminent)
                .tint(Color.systemBackground)
                .foregroundStyle(.primary)
                .buttonBorderShape(.capsule)
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        } else {
            content
                .buttonStyle(.bordered)
                .tint(.white)
                .buttonBorderShape(.capsule)
        }
    }
}

/// Primary sign-in CTA. Liquid Glass, tinted with the accent, so the button
/// sits in the sky instead of on top of it; the shared style supplies the
/// size, press feedback and the Reduce Transparency fallback.
struct PrimaryButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.catbird(.glassProminent, size: .lg, fullWidth: true))
    }
}
