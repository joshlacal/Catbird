import SwiftUI
import Petrel

// MARK: - Email Update Sheet

struct EmailUpdateSheet: View {
    let currentEmail: String
    let emailAuthFactor: Bool?
    let ensurePermission: (GatewayPermission) async throws -> Void
    let onEmailUpdated: (String) -> Void
    
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var newEmail: String = ""
    @State private var emailAuthFactorChoice: Bool?
    @State private var token: String = ""
    @State private var isTokenRequired: Bool = false
    @State private var isUpdating: Bool = false
    @State private var isRequestingCode: Bool = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var emailTask: Task<Void, Never>?
    
    init(
        currentEmail: String,
        emailAuthFactor: Bool? = nil,
        ensurePermission: @escaping (GatewayPermission) async throws -> Void = { _ in },
        onEmailUpdated: @escaping (String) -> Void = { _ in }
    ) {
        self.currentEmail = currentEmail
        self.emailAuthFactor = emailAuthFactor
        self.ensurePermission = ensurePermission
        self.onEmailUpdated = onEmailUpdated
        _emailAuthFactorChoice = State(initialValue: emailAuthFactor)
    }
    
    private var effectiveEmail: String {
        let trimmed = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? currentEmail : trimmed
    }
    
    private var isBusy: Bool {
        isUpdating || isRequestingCode
    }
    
    private var canSubmit: Bool {
        guard !isBusy else { return false }
        let email = effectiveEmail
        guard !email.isEmpty && email.contains("@") else { return false }
        if isTokenRequired {
            return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Current Email") {
                    Text(currentEmail.isEmpty ? "No email set" : currentEmail)
                        .foregroundStyle(.secondary)
                }
                
                Section("New Email") {
                    TextField(currentEmail.isEmpty ? "Enter email address" : "Enter new email address", text: $newEmail)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled(true)
                        .disabled(isBusy)
                }
                
                Section {
                    if let initialAuth = emailAuthFactor {
                        Toggle("Require Email 2FA at Sign-In", isOn: Binding(
                            get: { emailAuthFactorChoice ?? initialAuth },
                            set: { emailAuthFactorChoice = $0 }
                        ))
                        .disabled(isBusy)
                    } else {
                        Picker("Require Email 2FA", selection: $emailAuthFactorChoice) {
                            Text("Keep current setting").tag(Bool?.none)
                            Text("Enabled").tag(Bool?.some(true))
                            Text("Disabled").tag(Bool?.some(false))
                        }
                        .disabled(isBusy)
                    }
                } header: {
                    Text("Two-Factor Authentication")
                } footer: {
                    Text("When enabled, sign-ins will require a verification code sent to your email address.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
                
                if isTokenRequired {
                    Section {
                        TextField("Confirmation Code", text: $token)
                            #if os(iOS)
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled(true)
                            .disabled(isBusy)
                        
                        Button {
                            emailTask?.cancel()
                            emailTask = Task { @MainActor in
                                await requestCode()
                            }
                        } label: {
                            if isRequestingCode {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Resend Code")
                            }
                        }
                        .disabled(isBusy)
                    } header: {
                        Text("Verification Code")
                    } footer: {
                        Text("A confirmation code was sent to \(currentEmail.isEmpty ? effectiveEmail : currentEmail). Please enter it above to finish updating.")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if let info = infoMessage {
                    Section {
                        Text(info)
                            .foregroundStyle(.secondary)
                            .appFont(AppTextRole.caption)
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .appFont(AppTextRole.caption)
                    }
                }
            }
            .navigationTitle("Update Email")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        emailTask?.cancel()
                        dismiss()
                    }
                    .disabled(isBusy)
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        emailTask?.cancel()
                        emailTask = Task { @MainActor in
                            await handleSubmit()
                        }
                    } label: {
                        if isUpdating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(isTokenRequired ? "Confirm" : "Update")
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .interactiveDismissDisabled(isBusy)
            .onDisappear {
                if !isUpdating {
                    emailTask?.cancel()
                }
            }
        }
    }
    
    @MainActor
    private func requestCode() async {
        let email = effectiveEmail
        let authFactor = emailAuthFactorChoice
        
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available."
            return
        }
        
        isRequestingCode = true
        errorMessage = nil
        infoMessage = nil
        
        do {
            try await ensurePermission(.accountEmailManage)
            guard !Task.isCancelled else { return }
            
            let (responseCode, data) = try await client.com.atproto.server.requestEmailUpdate()
            guard !Task.isCancelled else { return }
            
            if (200...299).contains(responseCode) {
                if data?.tokenRequired == true {
                    isTokenRequired = true
                    infoMessage = "Verification code resent."
                    isRequestingCode = false
                } else {
                    isRequestingCode = false
                    await performUpdate(email: email, authFactor: authFactor, token: nil)
                }
            } else {
                errorMessage = "Failed to request verification code (Code: \(responseCode))."
                isRequestingCode = false
            }
        } catch let error as GatewayPermissionError where error == .cancelled {
            guard !Task.isCancelled else { return }
            errorMessage = nil
            isRequestingCode = false
        } catch is CancellationError {
            // Task cancelled
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            isRequestingCode = false
        }
    }
    
    @MainActor
    private func handleSubmit() async {
        let email = effectiveEmail
        guard !email.isEmpty && email.contains("@") else {
            errorMessage = "Please enter a valid email address."
            return
        }
        
        let authFactor = emailAuthFactorChoice
        let currentToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if isTokenRequired && currentToken.isEmpty {
            errorMessage = "Please enter the confirmation code."
            return
        }
        
        guard let client = appState.atProtoClient else {
            errorMessage = "Client not available."
            return
        }
        
        isUpdating = true
        errorMessage = nil
        infoMessage = nil
        
        do {
            // Immediately before account calls ensure accountEmailManage
            try await ensurePermission(.accountEmailManage)
            guard !Task.isCancelled else { return }
            
            if isTokenRequired {
                await performUpdate(email: email, authFactor: authFactor, token: currentToken)
            } else {
                // Request email update first
                let (responseCode, data) = try await client.com.atproto.server.requestEmailUpdate()
                guard !Task.isCancelled else { return }
                
                if (200...299).contains(responseCode) {
                    if data?.tokenRequired == true {
                        isTokenRequired = true
                        infoMessage = "A verification code has been sent. Please enter it below to complete the update."
                        isUpdating = false
                    } else {
                        // If no token required call immediately
                        await performUpdate(email: email, authFactor: authFactor, token: nil)
                    }
                } else {
                    errorMessage = "Failed to request email update (Code: \(responseCode))."
                    isUpdating = false
                }
            }
        } catch let error as GatewayPermissionError where error == .cancelled {
            guard !Task.isCancelled else { return }
            errorMessage = nil
            isUpdating = false
        } catch is CancellationError {
            // Task cancelled
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            isUpdating = false
        }
    }
    
    @MainActor
    private func performUpdate(email: String, authFactor: Bool?, token: String?) async {
        guard let client = appState.atProtoClient else {
            if !Task.isCancelled {
                errorMessage = "Client not available."
                isUpdating = false
            }
            return
        }
        
        isUpdating = true
        
        do {
            // Immediately before account calls ensure accountEmailManage
            try await ensurePermission(.accountEmailManage)
            guard !Task.isCancelled else { return }
            let input = ComAtprotoServerUpdateEmail.Input(
                email: email,
                emailAuthFactor: authFactor,
                token: token
            )
            let responseCode = try await client.com.atproto.server.updateEmail(input: input)
            
            if (200...299).contains(responseCode) {
                onEmailUpdated(email)
                dismiss()
                return
            } else if !Task.isCancelled {
                errorMessage = "Failed to update email (Code: \(responseCode))."
                isUpdating = false
            }
        } catch let error as ATProtoError<ComAtprotoServerUpdateEmail.Error> {
            guard !Task.isCancelled else { return }
            switch error.error {
            case .tokenRequired:
                isTokenRequired = true
                infoMessage = "A confirmation token is required. Please check your email."
            case .invalidToken:
                errorMessage = "Invalid confirmation token. Please check the code and try again."
            case .expiredToken:
                errorMessage = "Confirmation token has expired. Please request a new code."
            }
            isUpdating = false
        } catch let error as GatewayPermissionError where error == .cancelled {
            guard !Task.isCancelled else { return }
            errorMessage = nil
            isUpdating = false
        } catch is CancellationError {
            // Task cancelled
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            isUpdating = false
        }
    }
}

// MARK: - Handle Update Sheet

enum HandleType: String, CaseIterable, Identifiable {
    case serviceDomain = "Bluesky Handle"
    case customDomain = "Custom Domain"
    
    var id: String { rawValue }
}

struct HandleUpdateSheet: View {
    let currentHandle: String
    let ensurePermission: (GatewayPermission) async throws -> Void
    let onHandleUpdated: (String) -> Void
    
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var handleType: HandleType = .serviceDomain
    
    // Service Domain Handle State
    @State private var localPart: String = ""
    @State private var selectedDomain: String = "bsky.social"
    @State private var availableDomains: [String] = ["bsky.social"]
    @State private var isLoadingDomains = false
    @State private var isCheckingAvailability = false
    @State private var isAvailable: Bool?
    @State private var availabilityMessage: String?
    
    // Custom Domain State
    @State private var customDomain: String = ""
    @State private var isVerifyingDomain = false
    @State private var isDomainVerified: Bool?
    @State private var domainVerificationMessage: String?
    
    // Shared State
    @State private var isUpdating = false
    @State private var errorMessage: String?
    @State private var checkTask: Task<Void, Never>?
    @State private var verifyTask: Task<Void, Never>?
    @State private var updateTask: Task<Void, Never>?
    @State private var loadDomainsTask: Task<Void, Never>?
    
    init(
        currentHandle: String,
        ensurePermission: @escaping (GatewayPermission) async throws -> Void = { _ in },
        onHandleUpdated: @escaping (String) -> Void = { _ in }
    ) {
        self.currentHandle = currentHandle
        self.ensurePermission = ensurePermission
        self.onHandleUpdated = onHandleUpdated
    }
    
    private var cleanedLocalPart: String {
        localPart
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }
    
    private var cleanedCustomDomain: String {
        customDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }
    
    private var fullServiceHandleString: String {
        let domain = selectedDomain.hasPrefix(".") ? String(selectedDomain.dropFirst()) : selectedDomain
        guard !cleanedLocalPart.isEmpty else { return "" }
        return "\(cleanedLocalPart).\(domain)"
    }
    
    private var effectiveHandleString: String {
        switch handleType {
        case .serviceDomain:
            return fullServiceHandleString
        case .customDomain:
            return cleanedCustomDomain
        }
    }
    
    private var canUpdate: Bool {
        guard !isUpdating else { return false }
        switch handleType {
        case .serviceDomain:
            return !cleanedLocalPart.isEmpty &&
                !isCheckingAvailability &&
                isAvailable == true
        case .customDomain:
            return !cleanedCustomDomain.isEmpty &&
                !isVerifyingDomain &&
                isDomainVerified == true
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Current Handle") {
                    Text("@\(currentHandle)")
                        .foregroundStyle(.secondary)
                }
                
                Section {
                    Picker("Handle Type", selection: $handleType) {
                        ForEach(HandleType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                
                switch handleType {
                case .serviceDomain:
                    serviceDomainSection
                case .customDomain:
                    customDomainSection
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .appFont(AppTextRole.caption)
                    }
                }
                
                Section {
                    Text("Your handle is your unique identifier on AT Protocol. Changing it updates how other users mention you.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Change Handle")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        cancelTasks()
                        dismiss()
                    }
                    .disabled(isUpdating)
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard let handle = try? Handle(handleString: effectiveHandleString) else {
                            errorMessage = "Invalid handle format."
                            return
                        }
                        updateTask?.cancel()
                        updateTask = Task { @MainActor in
                            await updateHandle(handle: handle)
                        }
                    } label: {
                        if isUpdating {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Update")
                        }
                    }
                    .disabled(!canUpdate)
                }
            }
            .task {
                await loadServerDomains()
            }
            .interactiveDismissDisabled(isUpdating)
            .onDisappear {
                cancelTasks()
            }
        }
    }
    
    private func cancelTasks() {
        checkTask?.cancel()
        checkTask = nil
        verifyTask?.cancel()
        verifyTask = nil
        loadDomainsTask?.cancel()
        loadDomainsTask = nil
        if !isUpdating {
            updateTask?.cancel()
            updateTask = nil
        }
    }
    
    // MARK: - Service Domain Subview
    
    private var serviceDomainSection: some View {
        Group {
            Section("New Handle") {
                HStack(spacing: 4) {
                    Text("@")
                        .foregroundStyle(.secondary)
                    
                    TextField("username", text: $localPart)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled(true)
                        .disabled(isUpdating)
                        .onChange(of: localPart) {
                            checkServiceHandleAvailability()
                        }
                    
                    if availableDomains.count > 1 {
                        Picker("", selection: $selectedDomain) {
                            ForEach(availableDomains, id: \.self) { domain in
                                let display = domain.hasPrefix(".") ? domain : ".\(domain)"
                                Text(display).tag(domain)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedDomain) {
                            checkServiceHandleAvailability()
                        }
                    } else {
                        let domain = selectedDomain.hasPrefix(".") ? selectedDomain : ".\(selectedDomain)"
                        Text(domain)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if isCheckingAvailability {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking availability...")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let isAvailable = isAvailable {
                    HStack(spacing: 8) {
                        Image(systemName: isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isAvailable ? .green : .red)
                        Text(availabilityMessage ?? (isAvailable ? "Handle available" : "Handle not available"))
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(isAvailable ? .green : .red)
                    }
                } else if let availabilityMessage = availabilityMessage {
                    Text(availabilityMessage)
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    // MARK: - Custom Domain Subview
    
    private var customDomainSection: some View {
        Group {
            Section("Your Domain") {
                HStack {
                    Text("@")
                        .foregroundStyle(.secondary)
                    TextField("example.com", text: $customDomain)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled(true)
                        .disabled(isUpdating)
                        .onChange(of: customDomain) {
                            isDomainVerified = nil
                            domainVerificationMessage = nil
                        }
                }
                
                Button {
                    verifyCustomDomain()
                } label: {
                    if isVerifyingDomain {
                        HStack {
                            Text("Verifying Domain...")
                            Spacer()
                            ProgressView()
                                .controlSize(.small)
                        }
                    } else {
                        Text("Verify DNS Record")
                    }
                }
                .disabled(cleanedCustomDomain.isEmpty || isVerifyingDomain || isUpdating)
                
                if let isDomainVerified = isDomainVerified {
                    HStack(spacing: 8) {
                        Image(systemName: isDomainVerified ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isDomainVerified ? .green : .red)
                        Text(domainVerificationMessage ?? (isDomainVerified ? "Domain verified!" : "Verification failed"))
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(isDomainVerified ? .green : .red)
                    }
                } else if let domainVerificationMessage = domainVerificationMessage {
                    Text(domainVerificationMessage)
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("Verification Instructions") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Verify ownership of your domain using either method below before tapping Verify:")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    
                    // Method 1: DNS TXT
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Option A: DNS TXT Record (Recommended)")
                            .fontWeight(.medium)
                            .appFont(AppTextRole.subheadline)
                        
                        let domainText = cleanedCustomDomain.isEmpty ? "yourdomain.com" : cleanedCustomDomain
                        (Text("Host / Name: ")
                            .fontWeight(.semibold)
                        + Text("_atproto.\(domainText)")
                            .fontDesign(.monospaced))
                            .appFont(AppTextRole.caption)
                        
                        (Text("Type: ")
                            .fontWeight(.semibold)
                        + Text("TXT"))
                            .appFont(AppTextRole.caption)
                        
                        (Text("Value: ")
                            .fontWeight(.semibold)
                        + Text("did=\(appState.userDID)")
                            .fontDesign(.monospaced))
                            .appFont(AppTextRole.caption)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                    
                    // Method 2: HTTPS Well-Known
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Option B: HTTPS Well-Known URL")
                            .fontWeight(.medium)
                            .appFont(AppTextRole.subheadline)
                        
                        let domainText = cleanedCustomDomain.isEmpty ? "yourdomain.com" : cleanedCustomDomain
                        (Text("URL: ")
                            .fontWeight(.semibold)
                        + Text("https://\(domainText)/.well-known/atproto-did")
                            .fontDesign(.monospaced))
                            .appFont(AppTextRole.caption)
                        
                        (Text("Content: ")
                            .fontWeight(.semibold)
                        + Text(appState.userDID)
                            .fontDesign(.monospaced))
                            .appFont(AppTextRole.caption)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
            }
        }
    }
    
    // MARK: - Actions & Async Checks
    
    @MainActor
    private func loadServerDomains() async {
        guard let client = appState.atProtoClient else { return }
        isLoadingDomains = true
        defer { isLoadingDomains = false }
        
        do {
            let (code, data) = try await client.com.atproto.server.describeServer()
            if code == 200, let serverData = data, !serverData.availableUserDomains.isEmpty {
                self.availableDomains = serverData.availableUserDomains
                if !serverData.availableUserDomains.contains(selectedDomain),
                   let first = serverData.availableUserDomains.first {
                    self.selectedDomain = first
                }
            }
        } catch {
            // Keep default domain "bsky.social"
        }
    }
    
    @MainActor
    private func checkServiceHandleAvailability() {
        checkTask?.cancel()
        
        let candidate = fullServiceHandleString
        guard !cleanedLocalPart.isEmpty else {
            isAvailable = nil
            availabilityMessage = nil
            isCheckingAvailability = false
            return
        }
        
        if candidate.lowercased() == currentHandle.lowercased() {
            isAvailable = nil
            availabilityMessage = "This is your current handle."
            isCheckingAvailability = false
            return
        }
        
        guard let validatedHandle = try? Handle(handleString: candidate) else {
            isAvailable = false
            availabilityMessage = "Invalid handle format."
            isCheckingAvailability = false
            return
        }
        
        isCheckingAvailability = true
        isAvailable = nil
        availabilityMessage = nil
        
        checkTask = Task { @MainActor in
            guard let client = appState.atProtoClient else {
                if !Task.isCancelled {
                    isCheckingAvailability = false
                    isAvailable = nil
                    availabilityMessage = "Client not available."
                }
                return
            }
            
            do {
                let (responseCode, _) = try await client.com.atproto.identity.resolveHandle(
                    input: .init(handle: validatedHandle)
                )
                guard !Task.isCancelled else { return }
                
                if (200...299).contains(responseCode) {
                    isAvailable = false
                    availabilityMessage = "Handle is already taken."
                } else {
                    isAvailable = nil
                    availabilityMessage = "Unable to verify handle availability (Code: \(responseCode))."
                }
            } catch let protoError as ATProtoError<ComAtprotoIdentityResolveHandle.Error> where protoError.error == .handleNotFound {
                guard !Task.isCancelled else { return }
                isAvailable = true
                availabilityMessage = "Handle available."
            } catch let xrpcError as ATProtoXRPCError where xrpcError.error == "HandleNotFound" || xrpcError.error == ComAtprotoIdentityResolveHandle.Error.handleNotFound.rawValue {
                guard !Task.isCancelled else { return }
                isAvailable = true
                availabilityMessage = "Handle available."
            } catch {
                guard !Task.isCancelled else { return }
                isAvailable = nil
                availabilityMessage = "Could not check availability: \(error.localizedDescription)"
            }
            if !Task.isCancelled {
                isCheckingAvailability = false
            }
        }
    }
    
    @MainActor
    private func verifyCustomDomain() {
        verifyTask?.cancel()
        
        let candidate = cleanedCustomDomain
        guard !candidate.isEmpty else { return }
        
        guard let validatedHandle = try? Handle(handleString: candidate) else {
            isDomainVerified = false
            domainVerificationMessage = "Invalid domain format."
            return
        }
        
        isVerifyingDomain = true
        isDomainVerified = nil
        domainVerificationMessage = nil
        errorMessage = nil
        
        verifyTask = Task { @MainActor in
            defer {
                if !Task.isCancelled {
                    isVerifyingDomain = false
                }
            }
            
            guard let client = appState.atProtoClient else {
                if !Task.isCancelled {
                    isDomainVerified = false
                    domainVerificationMessage = "Client not available."
                }
                return
            }
            
            do {
                let (code, data) = try await client.com.atproto.identity.resolveHandle(
                    input: .init(handle: validatedHandle)
                )
                guard !Task.isCancelled else { return }
                
                if code == 200, let resolved = data {
                    let resolvedDID = resolved.did.description
                    let currentDID = appState.userDID
                    if resolvedDID.lowercased() == currentDID.lowercased() {
                        isDomainVerified = true
                        domainVerificationMessage = "Domain verified! Correctly resolves to your DID."
                    } else {
                        isDomainVerified = false
                        domainVerificationMessage = "Domain resolves to \(resolvedDID), but your account DID is \(currentDID)."
                    }
                } else {
                    isDomainVerified = false
                    domainVerificationMessage = "Could not resolve domain (Code: \(code))."
                }
            } catch let protoError as ATProtoError<ComAtprotoIdentityResolveHandle.Error> where protoError.error == .handleNotFound {
                guard !Task.isCancelled else { return }
                isDomainVerified = false
                domainVerificationMessage = "Domain does not resolve to any DID. Please check your DNS TXT or well-known setup."
            } catch let xrpcError as ATProtoXRPCError where xrpcError.error == "HandleNotFound" || xrpcError.error == ComAtprotoIdentityResolveHandle.Error.handleNotFound.rawValue {
                guard !Task.isCancelled else { return }
                isDomainVerified = false
                domainVerificationMessage = "Domain does not resolve to any DID. Please check your DNS TXT or well-known setup."
            } catch {
                guard !Task.isCancelled else { return }
                isDomainVerified = false
                domainVerificationMessage = "Verification failed: \(error.localizedDescription)"
            }
        }
    }
    
    @MainActor
    private func updateHandle(handle: Handle) async {
        guard let client = appState.atProtoClient else {
            if !Task.isCancelled {
                errorMessage = "Client not available."
            }
            return
        }
        
        isUpdating = true
        errorMessage = nil
        
        do {
            try await ensurePermission(.identityHandle)
            guard !Task.isCancelled else { return }
            
            let input = ComAtprotoIdentityUpdateHandle.Input(handle: handle)
            let responseCode = try await client.com.atproto.identity.updateHandle(input: input)
            
            if (200...299).contains(responseCode) {
                onHandleUpdated(handle.value)
                dismiss()
                return
            } else if !Task.isCancelled {
                errorMessage = "Failed to update handle (Code: \(responseCode)). Please try again."
                isUpdating = false
            }
        } catch let error as GatewayPermissionError where error == .cancelled {
            guard !Task.isCancelled else { return }
            errorMessage = nil
            isUpdating = false
        } catch is CancellationError {
            // Task cancelled
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            isUpdating = false
        }
    }
}

// MARK: - Previews

#Preview("Email Update Sheet") {
    EmailUpdateSheet(
        currentEmail: "user@example.com",
        emailAuthFactor: false,
        ensurePermission: { _ in },
        onEmailUpdated: { _ in }
    )
    .previewWithAuthenticatedState()
}

#Preview("Handle Update Sheet") {
    HandleUpdateSheet(
        currentHandle: "user.bsky.social",
        ensurePermission: { _ in },
        onHandleUpdated: { _ in }
    )
    .previewWithAuthenticatedState()
}
