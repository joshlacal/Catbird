import Contacts
import OSLog
import Petrel
import SwiftUI

/// Find Contacts / Address Book matching flow view (G64)
public struct FindContactsFlowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    
    public var isOnboarding: Bool = false
    public var onFinish: (() -> Void)?
    public var onSkip: (() -> Void)?
    
    // Flow step state
    private enum FlowStep: Equatable {
        case intro
        case phoneEntry
        case phoneCodeEntry
        case importing
        case results
        case permissionDenied
        case error(String)
    }
    
    @State private var step: FlowStep = .intro
    @State private var service = ContactMatchingService()
    
    // Phone Verification State
    @State private var phoneNumber: String = ""
    @State private var verificationCode: String = ""
    @State private var isSendingCode: Bool = false
    @State private var isVerifyingCode: Bool = false
    @State private var resendCountdown: Int = 0
    @State private var resendTimer: Task<Void, Never>?
    
    // Matches State
    @State private var matches: [ContactMatch] = []
    @State private var unmatchedContacts: [LocalContact] = []
    @State private var isFollowingAll: Bool = false
    @State private var errorMessage: String?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "FindContactsFlowView")
    
    public init(
        isOnboarding: Bool = false,
        onFinish: (() -> Void)? = nil,
        onSkip: (() -> Void)? = nil
    ) {
        self.isOnboarding = isOnboarding
        self.onFinish = onFinish
        self.onSkip = onSkip
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
                
                contentForCurrentStep
                    .animation(.easeInOut(duration: 0.25), value: step)
            }
            .navigationTitle(navigationTitleText)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if isOnboarding {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Skip") {
                            handleSkip()
                        }
                        .font(.body)
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
            .onDisappear {
                resendTimer?.cancel()
                resendTimer = nil
            }
        }
    }
    
    private var navigationTitleText: String {
        switch step {
        case .intro: return "Find Friends"
        case .phoneEntry, .phoneCodeEntry: return "Verify Phone"
        case .importing: return "Finding Friends"
        case .results: return "Contacts on Bluesky"
        case .permissionDenied: return "Contacts Permission"
        case .error: return "Find Friends"
        }
    }
    
    // MARK: - Step Router
    
    @ViewBuilder
    private var contentForCurrentStep: some View {
        switch step {
        case .intro:
            introStepView
        case .phoneEntry:
            phoneEntryStepView
        case .phoneCodeEntry:
            phoneCodeEntryStepView
        case .importing:
            importingStepView
        case .results:
            resultsStepView
        case .permissionDenied:
            permissionDeniedStepView
        case .error(let message):
            errorStepView(message: message)
        }
    }
    
    // MARK: - Step 1: Intro / Permission
    
    private var introStepView: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)
            
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 88, height: 88)
                
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.accentColor)
            }
            
            VStack(spacing: 10) {
                Text("Find Friends on Bluesky")
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                Text("Connect with people you know by matching your phone contacts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            
            // Privacy Explainer Card
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text("Your Privacy Matters")
                        .font(.headline)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Color.accentColor)
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    privacyBullet(
                        icon: "phone.badge.checkmark",
                        title: "Phone Numbers Only",
                        detail: "Only normalized phone numbers are uploaded for matching. Contact names, photos, and notes stay on your device."
                    )
                    privacyBullet(
                        icon: "trash.slash",
                        title: "No Data Retained",
                        detail: "Phone numbers are discarded after matching per the Bluesky contact service privacy policy."
                    )
                    privacyBullet(
                        icon: "hand.raised",
                        title: "You're in Control",
                        detail: "You can remove synced contact data at any time from your settings."
                    )
                }
            }
            .padding(18)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 20)
            
            Spacer(minLength: 16)
            
            // Actions
            VStack(spacing: 12) {
                Button {
                    handleRequestPermission()
                } label: {
                    Text("Find My Contacts")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                
                if isOnboarding {
                    Button {
                        handleSkip()
                    } label: {
                        Text("Not Now")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
    
    private func privacyBullet(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Step 2: Phone Entry
    
    private var phoneEntryStepView: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)
            
            Image(systemName: "message.badge.filled.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            
            VStack(spacing: 8) {
                Text("Verify Your Phone Number")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("We'll send a one-time SMS verification code to verify your phone number before matching contacts.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Phone Number")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                
                TextField("+1 (555) 000-0000", text: $phoneNumber)
                    .font(.title3)
                    #if os(iOS)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    #endif
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 24)
            
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }
            
            Spacer(minLength: 16)
            
            Button {
                handleSendVerificationCode()
            } label: {
                HStack(spacing: 8) {
                    if isSendingCode {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(isSendingCode ? "Sending Code..." : "Send Verification Code")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingCode)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
    
    // MARK: - Step 3: Phone Code Entry
    
    private var phoneCodeEntryStepView: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)
            
            Image(systemName: "lock.rectangle.on.rectangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            
            VStack(spacing: 8) {
                Text("Enter Confirmation Code")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Enter the 6-digit code sent to your phone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                TextField("000000", text: $verificationCode)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    #endif
                    .padding(14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 48)
            
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 24)
            }
            
            // Resend code button
            if resendCountdown > 0 {
                Text("Resend code in \(resendCountdown)s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Resend Code") {
                    handleSendVerificationCode()
                }
                .font(.subheadline)
            }
            
            Spacer(minLength: 16)
            
            Button {
                handleVerifyCodeAndImport()
            } label: {
                HStack(spacing: 8) {
                    if isVerifyingCode {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(isVerifyingCode ? "Verifying..." : "Verify & Continue")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isVerifyingCode)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
    
    // MARK: - Step 4: Importing Spinner
    
    private var importingStepView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ProgressView()
                .scaleEffect(1.5)
                .tint(Color.accentColor)
            
            Text("Finding Contacts on Bluesky...")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Spacer()
        }
    }
    
    // MARK: - Step 5: Results View
    
    private var resultsStepView: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let error = errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                }
                
                // Header with match count and Follow All
                if !matches.isEmpty {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(matches.count) Friend\(matches.count == 1 ? "" : "s") Found")
                                .font(.title3)
                                .fontWeight(.bold)
                            Text("Follow your friends to see their posts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        let unFollowedCount = matches.filter { !$0.isFollowing }.count
                        if unFollowedCount > 0 {
                            Button {
                                handleFollowAll()
                            } label: {
                                HStack(spacing: 6) {
                                    if isFollowingAll {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    }
                                    Text("Follow All (\(unFollowedCount))")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                            }
                            .disabled(isFollowingAll)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    
                    // Matched Contacts List
                    LazyVStack(spacing: 12) {
                        ForEach(matches.indices, id: \.self) { index in
                            let match = matches[index]
                            if !match.isDismissed {
                                matchRow(match: match, index: index)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                } else {
                    // Zero Matches Empty State
                    VStack(spacing: 16) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                            .padding(.top, 32)
                        
                        Text("No Contacts on Bluesky Yet")
                            .font(.headline)
                        
                        Text("None of your phone contacts have joined Bluesky with their phone numbers yet. Invite them to connect!")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .padding(.vertical, 24)
                }
                
                // Unmatched Contacts Invite Section
                if !unmatchedContacts.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Invite Friends to Bluesky")
                            .font(.headline)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                        
                        LazyVStack(spacing: 8) {
                            ForEach(unmatchedContacts.prefix(20)) { contact in
                                unmatchedContactRow(contact: contact)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                
                // Bottom continue/finish button
                VStack {
                    Button {
                        handleFinish()
                    } label: {
                        Text(isOnboarding ? "Continue" : "Done")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
        }
    }
    
    private func matchRow(match: ContactMatch, index: Int) -> some View {
        HStack(spacing: 12) {
            // Avatar
            if let avatar = match.profile.avatar, let url = URL(string: avatar.uriString()) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Circle().fill(Color.secondary.opacity(0.2))
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Text(String(match.profile.displayName?.prefix(1) ?? match.profile.handle.description.prefix(1)).uppercased())
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                    }
            }
            
            // Name and handle
            VStack(alignment: .leading, spacing: 2) {
                Text(match.profile.displayName ?? match.profile.handle.description)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                
                Text("@\(match.profile.handle.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                if let localName = match.localContact?.displayName {
                    Text("In contacts: \(localName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Follow Button
            Button {
                toggleFollow(for: index)
            } label: {
                Text(match.isFollowing ? "Following" : "Follow")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(match.isFollowing ? Color.secondary.opacity(0.15) : Color.accentColor)
                    .foregroundColor(match.isFollowing ? .primary : .white)
                    .clipShape(Capsule())
            }
            
            // Dismiss Button
            Button {
                dismissMatch(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
    
    private func unmatchedContactRow(contact: LocalContact) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.secondary.opacity(0.12))
                .frame(width: 36, height: 36)
                .overlay {
                    Text(String(contact.displayName.prefix(1)).uppercased())
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let phone = contact.phoneNumbers.first {
                    Text(phone)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            let handle = appState.currentUserProfile?.handle.description ?? "user"
            let inviteURL = URL(string: "https://bsky.app/profile/\(handle)")!
            
            ShareLink(item: inviteURL, message: Text("Join me on Bluesky!")) {
                Text("Invite")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())
            }
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Permission Denied Step
    
    private var permissionDeniedStepView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            
            VStack(spacing: 8) {
                Text("Contacts Access Needed")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("To find your friends, please enable Contacts access for Catbird in your device's Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            
            Spacer()
            
            VStack(spacing: 12) {
                Button {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                    #endif
                } label: {
                    Text("Open Settings")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                
                if isOnboarding {
                    Button {
                        handleSkip()
                    } label: {
                        Text("Skip for Now")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
    
    // MARK: - Error Step
    
    private func errorStepView(message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
            
            VStack(spacing: 8) {
                Text("Couldn't Find Contacts")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            
            Spacer()
            
            VStack(spacing: 12) {
                Button {
                    step = .intro
                } label: {
                    Text("Try Again")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                
                if isOnboarding {
                    Button {
                        handleSkip()
                    } label: {
                        Text("Skip")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }
    
    // MARK: - Actions & Handlers
    
    private func handleRequestPermission() {
        Task { @MainActor in
            do {
                let granted = try await service.requestContactsAccess()
                if granted {
                    // Check if phone verification token already in memory
                    if service.verificationToken != nil {
                        await performImport()
                    } else {
                        step = .phoneEntry
                    }
                }
            } catch ContactMatchingError.permissionDenied, ContactMatchingError.permissionRestricted {
                step = .permissionDenied
            } catch {
                step = .error(error.localizedDescription)
            }
        }
    }
    
    private func handleSendVerificationCode() {
        guard let client = appState.atProtoClient else {
            errorMessage = "Not connected to Bluesky."
            return
        }
        
        isSendingCode = true
        errorMessage = nil
        
        Task { @MainActor in
            do {
                try await service.startPhoneVerification(phone: phoneNumber, client: client)
                isSendingCode = false
                step = .phoneCodeEntry
                startResendTimer()
            } catch {
                isSendingCode = false
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func startResendTimer() {
        resendTimer?.cancel()
        resendCountdown = 30
        resendTimer = Task { @MainActor in
            while resendCountdown > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                resendCountdown -= 1
            }
        }
    }
    
    private func handleVerifyCodeAndImport() {
        guard let client = appState.atProtoClient else {
            errorMessage = "Not connected to Bluesky."
            return
        }
        
        isVerifyingCode = true
        errorMessage = nil
        
        Task { @MainActor in
            do {
                _ = try await service.verifyPhone(phone: phoneNumber, code: verificationCode, client: client)
                isVerifyingCode = false
                await performImport()
            } catch {
                isVerifyingCode = false
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func performImport() async {
        guard let client = appState.atProtoClient, let token = service.verificationToken else {
            step = .error("Verification token missing. Please try again.")
            return
        }
        
        step = .importing
        
        do {
            let prepared = try service.fetchAndPrepareContacts(excludingSelfPhone: service.verifiedPhoneNumber)
            self.unmatchedContacts = prepared.unmatchedContacts
            
            if prepared.normalizedPhoneNumbers.isEmpty {
                self.matches = []
                step = .results
                return
            }
            
            let fetchedMatches = try await service.importContacts(token: token, prepared: prepared, client: client)
            self.matches = fetchedMatches
            step = .results
        } catch {
            step = .error(error.localizedDescription)
        }
    }
    
    private func toggleFollow(for index: Int) {
        guard index < matches.count else { return }
        let match = matches[index]
        let newStatus = !match.isFollowing
        matches[index].isFollowing = newStatus
        errorMessage = nil
        
        Task { @MainActor in
            do {
                let success: Bool
                if newStatus {
                    success = try await appState.follow(did: match.profile.did.didString())
                } else {
                    success = try await appState.unfollow(did: match.profile.did.didString())
                }
                if !success {
                    logger.warning("Follow/unfollow returned false for \(match.profile.did.didString())")
                    matches[index].isFollowing = !newStatus
                    errorMessage = "Could not update follow status for \(match.profile.displayName ?? match.profile.handle.description)"
                }
            } catch {
                logger.error("Failed to update follow status: \(error.localizedDescription)")
                matches[index].isFollowing = !newStatus
                errorMessage = "Failed to update follow status: \(error.localizedDescription)"
            }
        }
    }
    
    private func dismissMatch(at index: Int) {
        guard index < matches.count else { return }
        let match = matches[index]
        matches[index].isDismissed = true
        
        Task { @MainActor in
            guard let client = appState.atProtoClient else { return }
            try? await service.dismissMatch(did: match.profile.did, client: client)
        }
    }
    
    private func handleFollowAll() {
        isFollowingAll = true
        errorMessage = nil
        
        Task { @MainActor in
            var failureCount = 0
            for i in matches.indices {
                if !matches[i].isFollowing && !matches[i].isDismissed {
                    do {
                        let success = try await appState.follow(did: matches[i].profile.did.didString())
                        if success {
                            matches[i].isFollowing = true
                        } else {
                            failureCount += 1
                        }
                    } catch {
                        logger.error("Follow failed for match: \(error.localizedDescription)")
                        failureCount += 1
                    }
                }
            }
            isFollowingAll = false
            if failureCount > 0 {
                errorMessage = "Could not follow \(failureCount) contact\(failureCount == 1 ? "" : "s"). Please try again."
            }
        }
    }
    
    private func handleFinish() {
        if let onFinish {
            onFinish()
        } else {
            dismiss()
        }
    }
    
    private func handleSkip() {
        if let onSkip {
            onSkip()
        } else {
            dismiss()
        }
    }
}
