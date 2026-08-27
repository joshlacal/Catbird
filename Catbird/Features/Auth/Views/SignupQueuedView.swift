import Foundation
import OSLog
import Petrel
import SwiftUI

/// Non-dismissible wait screen for users placed in the signup queue during account creation
public struct SignupQueuedView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppStateManager.self) private var appStateManager
    @Environment(\.dismiss) private var dismiss
    
    // Callbacks
    public var onActivated: (() -> Void)?
    public var onSignOut: (() -> Void)?
    
    // State
    @State private var placeInQueue: Int?
    @State private var estimatedTimeMs: Int?
    @State private var isCheckingStatus: Bool = false
    @State private var errorMessage: String?
    @State private var pollingTask: Task<Void, Never>?
    @State private var hasStartedOnboarding: Bool = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "SignupQueuedView")
    
    public init(
        initialPlaceInQueue: Int? = nil,
        initialEstimatedTimeMs: Int? = nil,
        onActivated: (() -> Void)? = nil,
        onSignOut: (() -> Void)? = nil
    ) {
        self._placeInQueue = State(initialValue: initialPlaceInQueue.map { max(1, $0) })
        self._estimatedTimeMs = State(initialValue: initialEstimatedTimeMs)
        self.onActivated = onActivated
        self.onSignOut = onSignOut
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()
                
                VStack(spacing: 28) {
                    Spacer(minLength: 24)
                    
                    // Icon
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 100, height: 100)
                        
                        Image(systemName: "hourglass.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Color.accentColor)
                            .symbolEffect(.pulse, options: .repeating)
                    }
                    
                    // Title & Description
                    VStack(spacing: 8) {
                        Text("You're in Line!")
                            .font(.title)
                            .fontWeight(.bold)
                        
                        Text("Bluesky is currently experiencing high demand. Your account is queued and will be ready shortly.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    
                    // Queue Status Card
                    queueStatusCard
                        .padding(.horizontal, 20)
                    
                    if let error = errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .padding(.horizontal, 24)
                    }
                    
                    Spacer(minLength: 24)
                    
                    // Action Buttons
                    VStack(spacing: 12) {
                        Button {
                            Task {
                                await checkQueueStatus(isManual: true)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if isCheckingStatus {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(isCheckingStatus ? "Checking Status..." : "Check My Status")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(isCheckingStatus)
                        
                        Button(role: .destructive) {
                            handleSignOut()
                        } label: {
                            Text("Sign Out & Cancel")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .disabled(isCheckingStatus)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Account Queue")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sign Out") {
                        handleSignOut()
                    }
                }
            }
            .task {
                await checkQueueStatus(isManual: false)
                startPolling()
            }
            .onDisappear {
                stopPolling()
            }
        }
        .interactiveDismissDisabled(true)
    }
    
    // MARK: - Queue Status Card
    
    private var queueStatusCard: some View {
        VStack(spacing: 16) {
            if let place = placeInQueue {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Position in Queue")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        
                        Text("#\(place)")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "person.3.fill")
                        .font(.title)
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                
                Divider()
                    .padding(.horizontal, 16)
            }
            
            HStack(spacing: 12) {
                Image(systemName: "clock.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                
                Text(formattedEstimateText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .padding(.top, placeInQueue == nil ? 16 : 0)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private var formattedEstimateText: String {
        Self.formatEstimate(ms: estimatedTimeMs)
    }
    
    public static func formatEstimate(ms: Int?) -> String {
        guard let ms, ms > 0 else { return "Estimating wait time..." }
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let hours = minutes / 60
        
        if hours > 0 {
            return "Estimated wait: ~\(hours) hour\(hours == 1 ? "" : "s")"
        } else if minutes > 0 {
            return "Estimated wait: ~\(minutes) minute\(minutes == 1 ? "" : "s")"
        } else {
            return "Estimated wait: Less than a minute"
        }
    }
    
    // MARK: - Polling & Status Check
    
    private func startPolling() {
        stopPolling()
        pollingTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { break }
                await checkQueueStatus(isManual: false)
            }
        }
    }
    
    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
    
    private func checkQueueStatus(isManual: Bool) async {
        guard !isCheckingStatus else { return }
        guard let client = appState.atProtoClient else {
            if isManual {
                errorMessage = "Service unavailable. Please try again."
            }
            return
        }
        
        isCheckingStatus = true
        if isManual {
            errorMessage = nil
        }
        
        do {
            let (code, output) = try await client.com.atproto.temp.checkSignupQueue()
            
            await MainActor.run {
                self.isCheckingStatus = false
                
                guard code == 200, let queueOutput = output else {
                    if isManual {
                        self.errorMessage = "Could not check queue status (HTTP \(code)). Retrying automatically."
                    }
                    return
                }
                
                // Preserve existing position/estimate if new response omits them
                if let newPlace = queueOutput.placeInQueue {
                    self.placeInQueue = max(1, newPlace)
                }
                if let newEst = queueOutput.estimatedTimeMs {
                    self.estimatedTimeMs = newEst
                }
                
                if queueOutput.activated {
                    logger.info("Account is now activated! Transitioning to session refresh and onboarding")
                    handleActivated()
                } else {
                    logger.debug("Account remains queued. Place: \(self.placeInQueue ?? 0), Est: \(self.estimatedTimeMs ?? 0)ms")
                }
            }
        } catch {
            await MainActor.run {
                self.isCheckingStatus = false
                self.logger.error("Signup queue check failed: \(error.localizedDescription)")
                if isManual {
                    self.errorMessage = "Status check failed. Will retry in a moment."
                }
            }
        }
    }
    
    private func handleActivated() {
        guard !hasStartedOnboarding else { return }
        stopPolling()
        
        Task { @MainActor in
            guard let client = appState.atProtoClient else {
                errorMessage = "Service unavailable. Please tap Check My Status to retry."
                startPolling()
                return
            }
            
            // Refresh OAuth session to exchange queued token for activated session
            do {
                _ = try await client.refreshToken()
                logger.info("Successfully refreshed session after queue activation")
                
                // Verify session is actually active and usable via getSession probe
                let (sessionCode, sessionOutput) = try await client.com.atproto.server.getSession()
                guard sessionCode == 200, sessionOutput != nil else {
                    logger.error("Session probe returned HTTP \(sessionCode) after activation")
                    errorMessage = "Session verification failed (HTTP \(sessionCode)). Please retry."
                    startPolling()
                    return
                }
                
                hasStartedOnboarding = true
                
                // Dismiss queue screen and trigger onboarding
                appState.onboardingManager.isSignupQueued = false
                appState.onboardingManager.signupQueueState = nil
                if let onActivated {
                    onActivated()
                } else {
                    appState.onboardingManager.checkForWelcomeOnboarding(for: appState.userDID)
                    dismiss()
                }
            } catch {
                logger.error("Token refresh / verification after activation failed: \(error.localizedDescription)")
                errorMessage = "Activation refresh failed: \(error.localizedDescription). Please retry."
                startPolling()
            }
        }
    }
    
    private func handleSignOut() {
        stopPolling()
        appState.onboardingManager.isSignupQueued = false
        appState.onboardingManager.signupQueueState = nil
        
        if let onSignOut {
            onSignOut()
        } else {
            Task { @MainActor in
                let did = appState.userDID
                try? await appState.removeAccount(did: did)
                dismiss()
            }
        }
    }
}
