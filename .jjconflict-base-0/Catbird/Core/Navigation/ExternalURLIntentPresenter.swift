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

    init() {}

    func handleIntent(_ intent: ExternalURLIntent, from url: URL, appState: AppState?) {
        let urlString = url.absoluteString
        if lastDeliveredURL == urlString {
            logger.info("Ignoring duplicate intent delivery for URL: \(urlString, privacy: .private)")
            return
        }
        lastDeliveredURL = urlString

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
    }
}

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
                    Text("Email Confirmed!")
                        .font(.title2.bold())
                    Text("Your email address \(email) has been verified successfully.")
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

                    Text(email.isEmpty ? "Confirm email verification for your account?" : "Confirm email verification for **\(email)**?")
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
            errorMessage = "Not authenticated"
            return
        }
        do {
            let (statusCode, session) = try await client.com.atproto.server.getSession()
            guard (200 ... 299).contains(statusCode) else {
                errorMessage = "Failed to load account details (HTTP \(statusCode))."
                return
            }
            guard let sessionEmail = session?.email, !sessionEmail.isEmpty else {
                errorMessage = "No email address found for this account."
                return
            }
            self.email = sessionEmail
        } catch {
            errorMessage = "Failed to load account details: \(error.localizedDescription)"
        }
    }

    private func confirm() async {
        guard let client = appState.atProtoClient else {
            errorMessage = "Not authenticated"
            return
        }
        guard !email.isEmpty else {
            errorMessage = "Email address is required to confirm."
            return
        }

        isConfirming = true
        errorMessage = nil
        defer { isConfirming = false }

        do {
            let input = ComAtprotoServerConfirmEmail.Input(email: email, token: code)
            let statusCode = try await client.com.atproto.server.confirmEmail(input: input)
            guard (200 ... 299).contains(statusCode) else {
                errorMessage = "Failed to confirm email (HTTP \(statusCode))."
                return
            }

            // Refresh session info to update and verify emailConfirmed
            let (sessionStatus, session) = try await client.com.atproto.server.getSession()
            guard (200 ... 299).contains(sessionStatus), let session = session else {
                errorMessage = "Email confirmed, but failed to verify updated session status."
                return
            }

            if session.emailConfirmed == true {
                isSuccess = true
            } else {
                errorMessage = "Email confirmation could not be verified on your account."
            }
        } catch {
            errorMessage = "Failed to confirm email: \(error.localizedDescription)"
        }
    }
}

struct GroupChatJoinIntentView: View {
    let code: String
    @Environment(AppState.self) private var appState
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
                    ProgressView("Loading Group Preview...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isInvalid {
                    ContentUnavailableView {
                        Label("Invalid Invite Link", systemImage: "link.badge.plus")
                    } description: {
                        Text("This group invite link is invalid or malformed.")
                    }
                } else if isDisabled {
                    ContentUnavailableView {
                        Label("Invite Link Disabled", systemImage: "slash.circle")
                    } description: {
                        Text("This group invite link has been disabled by the group administrator.")
                    }
                } else if let joinedConvoId {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                    Text("Joined Group!")
                        .font(.title2.bold())
                    Button("Open Chat") {
                        dismiss()
                        #if os(iOS)
                        appState.navigationManager.navigate(to: .conversation(joinedConvoId))
                        #endif
                    }
                    .buttonStyle(.borderedProminent)
                } else if isPendingRequest {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    Text("Join Request Sent")
                        .font(.title2.bold())
                    Text("Your request to join has been sent to the group admins for approval.")
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
                        Label("Failed to Load Preview", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") {
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
        isLoading = true
        errorMessage = nil
        isInvalid = false
        isDisabled = false
        preview = nil

        guard let client = appState.atProtoClient else {
            errorMessage = "Not authenticated"
            isLoading = false
            return
        }

        do {
            let (statusCode, output) = try await client.chat.bsky.group.getJoinLinkPreviews(input: .init(codes: [code]))
            guard (200 ... 299).contains(statusCode) else {
                errorMessage = "Failed to load group preview (HTTP \(statusCode))."
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
                    errorMessage = "Received an unrecognized preview response."
                }
            } else {
                self.isInvalid = true
            }
        } catch {
            errorMessage = "Failed to load group preview: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func joinGroup() async {
        guard let client = appState.atProtoClient else {
            errorMessage = "Not authenticated"
            return
        }
        isJoining = true
        errorMessage = nil
        defer { isJoining = false }

        do {
            let (statusCode, output) = try await client.chat.bsky.group.requestJoin(input: .init(code: code))
            guard (200 ... 299).contains(statusCode) else {
                errorMessage = "Failed to join group (HTTP \(statusCode))."
                return
            }

            guard let output = output else {
                errorMessage = "Failed to receive valid response from server."
                return
            }

            switch output.status {
            case "joined":
                if let convoId = output.convo?.id {
                    self.joinedConvoId = convoId
                } else {
                    errorMessage = "Joined group, but failed to load conversation details."
                }
            case "requested":
                self.isPendingRequest = true
            default:
                errorMessage = "Unexpected join response status: \(output.status)"
            }
        } catch {
            errorMessage = "Error joining group: \(error.localizedDescription)"
        }
    }
}
