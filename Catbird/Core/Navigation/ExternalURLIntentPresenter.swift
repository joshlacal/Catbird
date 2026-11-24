import Foundation
import SwiftUI
import Observation
import OSLog
import Petrel

@Observable
@MainActor
final class ExternalURLIntentPresenter {
    private let logger = Logger(subsystem: "blue.catbird", category: "ExternalURLIntentPresenter")

    var activeIntent: ExternalURLIntent?
    var pendingIntent: ExternalURLIntent?
    var lastDeliveredURL: String?
    /// The same URL can arrive twice in quick succession (scene `onOpenURL` plus `URLHandler`).
    /// Only that burst is ignored; tapping the same link again later opens it again.
    private var lastDeliveredAt: Date?
    private let duplicateDeliveryWindow: TimeInterval = 1

    init() {}

    func handleIntent(_ intent: ExternalURLIntent, from url: URL, appState: AppState?) {
        let urlString = url.absoluteString
        let now = Date()
        if lastDeliveredURL == urlString,
           let lastDeliveredAt,
           now.timeIntervalSince(lastDeliveredAt) < duplicateDeliveryWindow {
            logger.info("Ignoring duplicate intent delivery for URL: \(urlString, privacy: .private)")
            return
        }
        lastDeliveredURL = urlString
        lastDeliveredAt = now

        guard let appState = appState, appState.isAuthenticated else {
            logger.info("User not authenticated; retaining pending intent: \(String(describing: intent))")
            pendingIntent = intent
            return
        }

        logger.info("Presenting active intent: \(String(describing: intent))")
        activeIntent = intent
    }

    func flushPendingIntent(with appState: AppState) {
        guard let pending = pendingIntent, appState.isAuthenticated else { return }
        logger.info("Flushing pending intent after authentication: \(String(describing: pending))")
        pendingIntent = nil
        activeIntent = pending
    }

    func clearActiveIntent() {
        activeIntent = nil
        lastDeliveredURL = nil
        lastDeliveredAt = nil
    }
}

private let intentViewLogger = Logger(subsystem: "blue.catbird", category: "ExternalURLIntentViews")

// MARK: - Intent Dialog Views

struct VerifyEmailIntentView: View {
    let code: String
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var isConfirming = false
    @State private var isSuccess = false
    @State private var errorMessage: String?

    init(code: String) {
        self.code = code
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if isSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    Text("Email Confirmed", comment: "Title shown after an account email address is confirmed.")
                        .font(.title2.bold())
                    Text("\(email) is now confirmed.", comment: "Confirmation message — variable is the user's email address.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        dismiss()
                    } label: {
                        Text("Done", comment: "Button dismissing the email confirmation sheet.")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 10)
                } else {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)

                    Text("Confirm Email Address", comment: "Title of the email verification dialog.")
                        .font(.title2.bold())

                    Group {
                        if email.isEmpty {
                            Text("Confirm the email address for your account?", comment: "Prompt asking whether to confirm the account's email address before the address has loaded.")
                        } else {
                            Text("Confirm **\(email)** as your email address?", comment: "Prompt asking whether to confirm a specific email address — variable is the email address.")
                        }
                    }
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task { await confirm() }
                    } label: {
                        if isConfirming {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Confirm Email", comment: "Primary action button to confirm the user's email address.")
                                .bold()
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConfirming || email.isEmpty)
                    .padding(.top, 10)
                }
            }
            .padding(24)
            .navigationTitle(Text("Verify Email", comment: "Navigation bar title for email verification sheet."))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Cancel", comment: "Cancel button dismissing the email verification sheet.")
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .task {
            await loadCurrentEmail()
        }
    }

    private func loadCurrentEmail() async {
        guard let client = appState.atProtoClient else {
            errorMessage = String(localized: "Sign in to confirm your email.", comment: "Error shown when trying to verify email while signed out.")
            return
        }
        do {
            let (statusCode, session) = try await client.com.atproto.server.getSession()
            guard (200 ... 299).contains(statusCode) else {
                intentViewLogger.error("getSession failed with HTTP \(statusCode, privacy: .public)")
                errorMessage = String(localized: "Couldn’t load your account details. Try again.", comment: "Error shown when fetching account details for email confirmation fails.")
                return
            }
            guard let sessionEmail = session?.email, !sessionEmail.isEmpty else {
                errorMessage = String(localized: "This account doesn’t have an email address yet. Add one in Settings.", comment: "Error shown when confirming email on an account with no email configured.")
                return
            }
            self.email = sessionEmail
        } catch {
            intentViewLogger.error("getSession failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = UserFacingError.message(
                for: error,
                action: String(localized: "load your account details", comment: "Action phrase for loading account details.")
            )
        }
    }

    private func confirm() async {
        guard let client = appState.atProtoClient else {
            errorMessage = String(localized: "Sign in to confirm your email.", comment: "Error shown when trying to verify email while signed out.")
            return
        }
        guard !email.isEmpty else {
            errorMessage = String(localized: "Catbird couldn’t find the email address to confirm. Try again.", comment: "Error shown when email address is missing during confirmation.")
            return
        }

        isConfirming = true
        errorMessage = nil
        defer { isConfirming = false }

        do {
            let input = ComAtprotoServerConfirmEmail.Input(email: email, token: code)
            let statusCode = try await client.com.atproto.server.confirmEmail(input: input)
            guard (200 ... 299).contains(statusCode) else {
                intentViewLogger.error("confirmEmail failed with HTTP \(statusCode, privacy: .public)")
                errorMessage = String(localized: "We couldn’t confirm your email. The link may have expired. Request a new one from Settings.", comment: "Error shown when an email verification token fails or is expired.")
                return
            }

            // Refresh session info to update and verify emailConfirmed
            let (sessionStatus, session) = try await client.com.atproto.server.getSession()
            guard (200 ... 299).contains(sessionStatus), let session = session else {
                intentViewLogger.error("getSession after confirmEmail failed with HTTP \(sessionStatus, privacy: .public)")
                errorMessage = String(localized: "Your email may be confirmed, but Catbird couldn’t check. Look in Settings to make sure.", comment: "Message shown when post-confirmation session refresh fails.")
                return
            }

            if session.emailConfirmed == true {
                isSuccess = true
            } else {
                errorMessage = String(localized: "We couldn’t confirm your email. The link may have expired. Request a new one from Settings.", comment: "Error shown when email remains unconfirmed after submitting token.")
            }
        } catch {
            intentViewLogger.error("confirmEmail failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = UserFacingError.message(
                for: error,
                action: String(localized: "confirm your email", comment: "Action phrase for confirming email address.")
            )
        }
    }
}

struct GroupChatJoinIntentView: View {
    let code: String
    @Environment(AppState.self) private var appState
    @Environment(SceneNavigationContext.self) private var sceneNavigation
    @Environment(\.dismiss) private var dismiss

    @State private var preview: ChatBskyGroupDefs.JoinLinkPreviewView?
    @State private var isDisabled = false
    @State private var isInvalid = false
    @State private var isLoading = true
    @State private var isJoining = false
    @State private var joinedConvoId: String?
    @State private var isPendingRequest = false
    @State private var errorMessage: String?

    public init(code: String) {
        self.code = code
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if isLoading {
                    ProgressView {
                        Text("Loading invite…", comment: "Progress message while loading a group chat invite.")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isInvalid {
                    ContentUnavailableView {
                        Label {
                            Text("Invalid Invite Link", comment: "Empty-state title when a group chat invite link is invalid.")
                        } icon: {
                            Image(systemName: "link.badge.plus")
                        }
                    } description: {
                        Text("This invite link isn’t valid. Ask for a new one.", comment: "Description when a group chat invite link is invalid.")
                    }
                } else if isDisabled {
                    ContentUnavailableView {
                        Label {
                            Text("Invite Link Disabled", comment: "Empty-state title when a group chat invite link was disabled.")
                        } icon: {
                            Image(systemName: "slash.circle")
                        }
                    } description: {
                        Text("The group’s admin turned off this invite link.", comment: "Description when a group chat invite link was disabled by an admin.")
                    }
                } else if let joinedConvoId {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    Text("You’re in the Group", comment: "Confirmation heading after joining a group chat.")
                        .font(.title2.bold())
                    Button {
                        guard isCurrentScene(sceneNavigation) else { return }
                        dismiss()
                        #if os(iOS)
                        sceneNavigation.navigationManager.navigate(to: .conversation(joinedConvoId))
                        #endif
                    } label: {
                        Text("Open Chat", comment: "Button opening the newly joined group chat.")
                    }
                    .buttonStyle(.borderedProminent)
                } else if isPendingRequest {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    Text("Join Request Sent", comment: "Heading shown after requesting to join an approval-gated group chat.")
                        .font(.title2.bold())
                    Text("The group’s admins will review your request.", comment: "Subtext explaining that group chat admins will review a join request.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        dismiss()
                    } label: {
                        Text("Done", comment: "Button dismissing the group invite sheet.")
                    }
                    .buttonStyle(.bordered)
                } else if let preview {
                    groupPreviewContent(preview)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label {
                            Text("Couldn’t Load Invite", comment: "Error title when loading a group chat invite fails.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button {
                            Task { await loadPreview() }
                        } label: {
                            Text("Try Again", comment: "Button retrying loading a group chat invite.")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
            .navigationTitle(Text("Group Invite", comment: "Navigation bar title for a group chat invite sheet."))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Close", comment: "Toolbar button closing the group chat invite sheet.")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await loadPreview()
        }
    }

    @ViewBuilder
    private func groupPreviewContent(_ preview: ChatBskyGroupDefs.JoinLinkPreviewView) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 50))
                .foregroundColor(.accentColor)

            Group {
                if preview.name.isEmpty {
                    Text("Group Chat", comment: "Fallback title for an unnamed group chat in an invite preview.")
                } else {
                    Text(preview.name)
                }
            }
            .font(.title2.bold())

            HStack(spacing: 16) {
                Label {
                    Text("\(preview.memberCount) members", comment: "Member count in a group chat invite preview — variable is member count.")
                } icon: {
                    Image(systemName: "person.2")
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if preview.requireApproval {
                    Label {
                        Text("Approval Required", comment: "Badge indicating joining a group chat requires admin approval.")
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    .font(.caption)
                    .foregroundColor(.orange)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Button {
                Task { await joinGroup() }
            } label: {
                if isJoining {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Group {
                        if preview.requireApproval {
                            Text("Request to Join", comment: "Button requesting to join an approval-gated group chat.")
                        } else {
                            Text("Join Group", comment: "Button to immediately join a group chat.")
                        }
                    }
                    .bold()
                    .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isJoining)
            .padding(.top, 8)
        }
    }

    private func loadPreview() async {
        weak var operationScene = sceneNavigation
        guard isCurrentScene(operationScene) else { return }
        isLoading = true
        errorMessage = nil
        isInvalid = false
        isDisabled = false
        preview = nil

        guard let client = appState.atProtoClient else {
            errorMessage = String(localized: "Sign in to open this invite.", comment: "Error shown when opening a group invite while signed out.")
            isLoading = false
            return
        }

        do {
            let (statusCode, output) = try await client.chat.bsky.group.getJoinLinkPreviews(input: .init(codes: [code]))
            guard isCurrentScene(operationScene) else { return }
            guard (200 ... 299).contains(statusCode) else {
                intentViewLogger.error("getJoinLinkPreviews failed with HTTP \(statusCode, privacy: .public)")
                errorMessage = String(localized: "This invite couldn’t be loaded. It may have expired.", comment: "Error shown when a group invite link fails to load.")
                isLoading = false
                return
            }

            if let firstPreview = output?.joinLinkPreviews.first {
                switch firstPreview {
                case .chatBskyGroupDefsJoinLinkPreviewView(let view):
                    self.preview = view
                case .chatBskyGroupDefsDisabledJoinLinkPreviewView:
                    self.isDisabled = true
                case .chatBskyGroupDefsInvalidJoinLinkPreviewView:
                    self.isInvalid = true
                case .unexpected:
                    intentViewLogger.error("getJoinLinkPreviews returned an unrecognized preview type")
                    errorMessage = String(localized: "This invite couldn’t be loaded. It may have expired.", comment: "Error shown when a group invite link returns an unsupported preview type.")
                }
            } else {
                self.isInvalid = true
            }
        } catch {
            guard isCurrentScene(operationScene) else { return }
            intentViewLogger.error("getJoinLinkPreviews failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = UserFacingError.message(
                for: error,
                action: String(localized: "load this invite", comment: "Action phrase for loading a group chat invite.")
            )
        }
        isLoading = false
    }

    private func joinGroup() async {
        weak var operationScene = sceneNavigation
        guard isCurrentScene(operationScene) else { return }
        guard let client = appState.atProtoClient else {
            errorMessage = String(localized: "Sign in to join this group.", comment: "Error shown when attempting to join a group while signed out.")
            return
        }
        isJoining = true
        errorMessage = nil
        defer {
            if isCurrentScene(operationScene) {
                isJoining = false
            }
        }

        do {
            let (statusCode, output) = try await client.chat.bsky.group.requestJoin(input: .init(code: code))
            guard isCurrentScene(operationScene) else { return }
            guard (200 ... 299).contains(statusCode) else {
                intentViewLogger.error("requestJoin failed with HTTP \(statusCode, privacy: .public)")
                errorMessage = String(localized: "Couldn’t join this group. Try again.", comment: "Error shown when joining a group chat fails.")
                return
            }

            guard let output = output else {
                intentViewLogger.error("requestJoin returned no body")
                errorMessage = String(localized: "Couldn’t join this group. Try again.", comment: "Error shown when joining a group chat returns an empty response.")
                return
            }

            switch output.status {
            case "joined":
                if let convoId = output.convo?.id {
                    self.joinedConvoId = convoId
                } else {
                    errorMessage = String(localized: "You joined the group. Open Messages to find the conversation.", comment: "Fallback message when user joined a group chat without an immediate conversation ID.")
                }
            case "requested":
                self.isPendingRequest = true
            default:
                intentViewLogger.error("requestJoin returned unexpected status \(output.status, privacy: .public)")
                errorMessage = String(localized: "Couldn’t join this group. Try again.", comment: "Error shown when joining a group chat returns an unexpected status.")
            }
        } catch {
            guard isCurrentScene(operationScene) else { return }
            intentViewLogger.error("requestJoin failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = UserFacingError.message(
                for: error,
                action: String(localized: "join this group", comment: "Action phrase for joining a group chat.")
            )
        }
    }

    private func isCurrentScene(_ context: SceneNavigationContext?) -> Bool {
        guard let context else { return false }
        return context === sceneNavigation
            && !context.isInvalidated
            && context.accountDID == appState.userDID
            && appState.isAuthenticated
            && !Task.isCancelled
    }
}
