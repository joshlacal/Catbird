import SwiftUI
import Petrel

struct NuxAnnouncementView: View {
    let nuxID: NuxID
    let onDismiss: () -> Void
    @Environment(AppState.self) private var appState

    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pendingAction: CompletionAction?
    init(nuxID: NuxID, onDismiss: @escaping () -> Void) {
        self.nuxID = nuxID
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Icon / Illustration
                ZStack {
                    Circle()
                        .fill(iconGradient.opacity(0.15))
                        .frame(width: 100, height: 100)

                    Image(systemName: iconName)
                        .font(.system(size: 48))
                        .foregroundStyle(iconGradient)
                }

                // Title & Description
                VStack(spacing: 10) {
                    Text(title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    Text(description)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                Spacer()

                // Inline Error
                if let errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.leading)
                        Spacer()
                        Button("Retry") {
                            retryCompletion()
                        }
                        .font(.caption.bold())
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }

                // Actions
                VStack(spacing: 12) {
                    Button {
                        completeAndPerformFeatureAction()
                    } label: {
                        HStack(spacing: 8) {
                            if isSaving && pendingAction == .performFeature {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(actionButtonTitle)
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)

                    Button("Got It") {
                        completeAndDismiss()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .disabled(isSaving)
                }
            }
            .padding(24)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        completeAndDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    }
                    .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving)
    }

    private enum CompletionAction {
        case dismiss
        case performFeature
    }

    private var iconName: String {
        switch nuxID {
        case .draftsAnnouncement:
            return "square.and.pencil"
        case .bookmarksAnnouncement:
            return "bookmark.fill"
        case .groupChatsAnnouncement:
            return "person.3.sequence.fill"
        case .activitySubscriptions:
            return "bell.badge.fill"
        }
    }

    private var iconGradient: LinearGradient {
        switch nuxID {
        case .draftsAnnouncement:
            return LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .bookmarksAnnouncement:
            return LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .groupChatsAnnouncement:
            return LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .activitySubscriptions:
            return LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var title: String {
        switch nuxID {
        case .draftsAnnouncement:
            return "Post Drafts"
        case .bookmarksAnnouncement:
            return "Introducing Bookmarks"
        case .groupChatsAnnouncement:
            return "Group Chats are Here"
        case .activitySubscriptions:
            return "Activity Alerts"
        }
    }

    private var description: String {
        switch nuxID {
        case .draftsAnnouncement:
            return "Save your posts as drafts to edit and publish whenever you're ready. Access them directly from the composer."
        case .bookmarksAnnouncement:
            return "Save posts privately to read later. Access all your saved posts anytime in the new Bookmarks tab."
        case .groupChatsAnnouncement:
            return "Chat privately with multiple people at once. Create groups, share invite links, and stay connected."
        case .activitySubscriptions:
            return "Get instant notifications when your favorite accounts post, reply, or go live."
        }
    }

    private var actionButtonTitle: String {
        switch nuxID {
        case .draftsAnnouncement:
            return "Try It Out"
        case .bookmarksAnnouncement:
            return "View Bookmarks"
        case .groupChatsAnnouncement:
            return "Open Messages"
        case .activitySubscriptions:
            return "Manage Alerts"
        }
    }

    private func retryCompletion() {
        performCompletion(action: pendingAction ?? .dismiss)
    }

    private func completeAndDismiss() {
        performCompletion(action: .dismiss)
    }

    private func completeAndPerformFeatureAction() {
        performCompletion(action: .performFeature)
    }

    private func performCompletion(action: CompletionAction) {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        pendingAction = action

        Task { @MainActor in
            do {
                try await appState.preferencesManager.setNuxCompleted(nuxID.rawValue, completed: true)
                isSaving = false
                onDismiss()

                if action == .performFeature {
                    navigateToFeature()
                }
            } catch {
                // Roll back local SwiftData state so failed sync does not falsely suppress NUX
                if let prefs = try? await appState.preferencesManager.getPreferences() {
                    prefs.setNuxCompleted(nuxID.rawValue, completed: false)
                    try? await appState.preferencesManager.savePreferences(prefs)
                }
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func navigateToFeature() {
        switch nuxID {
        case .draftsAnnouncement:
            #if os(iOS)
            appState.navigationManager.updateCurrentTab(0)
            #endif
        case .bookmarksAnnouncement:
            appState.navigationManager.navigate(to: .bookmarks)
        case .groupChatsAnnouncement:
            #if os(iOS)
            appState.navigationManager.navigate(to: .chatTab)
            #endif
        case .activitySubscriptions:
            appState.navigationManager.navigate(to: .activitySubscriptions)
        }
    }
}
