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
                    Text("Email Confirmed")
                        .font(.title2.bold())
                    Text("\(email) is now confirmed.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 10)
                } else {
                    Image(systemName: "envelope.badge.shield.half.filled")
                        .font(.system(size: 60))
                        .foregroundColor(.accentColor)

                    Text("Confirm Email Address")
                        .font(.title2.bold())

                    Text(email.isEmpty ? "Confirm the email address for your account?" : "Confirm **\(email)** as your email address?")
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
                            Text("Confirm Email")
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
            .navigationTitle("Verify Email")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
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
            errorMessage = "Sign in to confirm your email."
            return
        }
        do {
            let (statusCode, session) = try await client.com.atproto.server.getSession()
            guard (200 ... 299).contains(statusCode) else {
                intentViewLogger.error("getSession failed with HTTP \(statusCode, privacy: .public)")
                errorMessage = "Couldn’t load your account details. Try again."
                return
            }
            guard let sessionEmail = session?.email, !sessionEmail.isEmpty else {
                errorMessage = "This account doesn’t have an email address yet. Add one in Settings."
                return
            }
            self.email = sessionEmail
        } catch {
            intentViewLogger.error("getSession failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = UserFacingError.message(for: error, action: "load your account details")
        }
    }

    private func confirm() async {
        guard let client = appState.atProtoClient else {
            errorMessage = "Sign in to confirm your email."
            return
        }
        guard !email.isEmpty else {
            errorMessage = "Catbird couldn’t find the email address to confirm. Try again."
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
                errorMessage = "We couldn’t confirm your email. The link may have expired. Request a new one from Settings."
                return
            }

            // Refresh session info to update and verify emailConfirmed
            let (sessionStatus, session) = try await client.com.atproto.server.getSession()
            guard (200 ... 299).contains(sessionStatus), let session = session else {
                intentViewLogger.error("getSession after confirmEmail failed with HTTP \(sessionStatus, privacy: .public)")
                errorMessage = "Your email may be confirmed, but Catbird couldn’t check. Look in Settings to make sure."
                return
            }

            if session.emailConfirmed == true {
                isSuccess = true
            } else {
                errorMessage = "We couldn’t confirm your email. The link may have expired. Request a new one from Settings."
            }
        } catch {
            intentViewLogger.error("confirmEmail failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = UserFacingError.message(for: error, action: "confirm your email")
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
                    ProgressView("Loading invite…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isInvalid {
                    ContentUnavailableView {
                        Label("Invalid Invite Link", systemImage: "link.badge.plus")
                    } description: {
                        Text("This invite link isn’t valid. Ask for a new one.")
                    }
                } else if isDisabled {
                    ContentUnavailableView {
                        Label("Invite Link Disabled", systemImage: "slash.circle")
                    } description: {
                        Text("The group’s admin turned off this invite link.")
                    }
                } else if let joinedConvoId {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    Text("You’re in the Group")
                        .font(.title2.bold())
                    Button("Open Chat") {
                        guard isCurrentScene(sceneNavigation) else { return }
                        dismiss()
                        #if os(iOS)
                        sceneNavigation.navigationManager.navigate(to: .conversation(joinedConvoId))
                        #endif
                    }
                    .buttonStyle(.borderedProminent)
                } else if isPendingRequest {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    Text("Join Request Sent")
                        .font(.title2.bold())
                    Text("The group’s admins will review your request.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                } else if let preview {
                    groupPreviewContent(preview)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t Load Invite", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            Task { await loadPreview() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
            .navigationTitle("Group Invite")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
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

            Text(preview.name.isEmpty ? "Group Chat" : preview.name)
                .font(.title2.bold())

            HStack(spacing: 16) {
                Label("\(preview.memberCount) members", systemImage: "person.2")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if preview.requireApproval {
                    Label("Approval Required", systemImage: "lock.shield")
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
                    Text(preview.requireApproval ? "Request to Join" : "Join Group")
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
            errorMessage = "Sign in to open this invite."
            isLoading = false
            return
        }

        do {
            let (statusCode, output) = try await client.chat.bsky.group.getJoinLinkPreviews(input: .init(codes: [code]))
            guard isCurrentScene(operationScene) else { return }
            guard (200 ... 299).contains(statusCode) else {
                intentViewLogger.error("getJoinLinkPreviews failed with HTTP \(statusCode, privacy: .public)")
                errorMessage = "This invite couldn’t be loaded. It may have expired."
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
                    errorMessage = "This invite couldn’t be loaded. It may have expired."
                }
            } else {
                self.isInvalid = true
            }
        } catch {
            guard isCurrentScene(operationScene) else { return }
            intentViewLogger.error("getJoinLinkPreviews failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = UserFacingError.message(for: error, action: "load this invite")
        }
        isLoading = false
    }

    private func joinGroup() async {
        weak var operationScene = sceneNavigation
        guard isCurrentScene(operationScene) else { return }
        guard let client = appState.atProtoClient else {
            errorMessage = "Sign in to join this group."
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
                errorMessage = "Couldn’t join this group. Try again."
                return
            }

            guard let output = output else {
                intentViewLogger.error("requestJoin returned no body")
                errorMessage = "Couldn’t join this group. Try again."
                return
            }

            switch output.status {
            case "joined":
                if let convoId = output.convo?.id {
                    self.joinedConvoId = convoId
                } else {
                    errorMessage = "You joined the group. Open Messages to find the conversation."
                }
            case "requested":
                self.isPendingRequest = true
            default:
                intentViewLogger.error("requestJoin returned unexpected status \(output.status, privacy: .public)")
                errorMessage = "Couldn’t join this group. Try again."
            }
        } catch {
            guard isCurrentScene(operationScene) else { return }
            intentViewLogger.error("requestJoin failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = UserFacingError.message(for: error, action: "join this group")
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
