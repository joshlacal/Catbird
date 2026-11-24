import SwiftUI
import Petrel

struct NuxAnnouncementView: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
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
                        Button {
                            retryCompletion()
                        } label: {
                            Text("Try Again", comment: "Button retrying saving the feature announcement dismissal.")
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

                    Button {
                        completeAndDismiss()
                    } label: {
                        Text("Got It", comment: "Button acknowledging and dismissing a feature announcement sheet.")
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
                    .accessibilityLabel(Text("Close", comment: "Accessibility label for the button closing a feature announcement sheet."))
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

    private var title: LocalizedStringResource {
        switch nuxID {
        case .draftsAnnouncement:
            return LocalizedStringResource("Post Drafts", comment: "Feature announcement title for post drafts.")
        case .bookmarksAnnouncement:
            return LocalizedStringResource("Introducing Bookmarks", comment: "Feature announcement title for bookmarks.")
        case .groupChatsAnnouncement:
            return LocalizedStringResource("Group Chats Are Here", comment: "Feature announcement title for group chats.")
        case .activitySubscriptions:
            return LocalizedStringResource("Activity Alerts", comment: "Feature announcement title for activity alerts.")
        }
    }

    private var description: LocalizedStringResource {
        switch nuxID {
        case .draftsAnnouncement:
            return LocalizedStringResource("Save your posts as drafts to edit and publish whenever you’re ready. Find them in the composer.", comment: "Feature announcement description for post drafts.")
        case .bookmarksAnnouncement:
            return LocalizedStringResource("Save posts privately to read later. Find them anytime in Bookmarks, from the feeds menu.", comment: "Feature announcement description for bookmarks.")
        case .groupChatsAnnouncement:
            return LocalizedStringResource("Chat privately with multiple people at once. Create groups, share invite links, and stay connected.", comment: "Feature announcement description for group chats.")
        case .activitySubscriptions:
            return LocalizedStringResource("Get notified when your favorite accounts post or reply.", comment: "Feature announcement description for activity alerts.")
        }
    }

    private var actionButtonTitle: LocalizedStringResource {
        switch nuxID {
        case .draftsAnnouncement:
            return LocalizedStringResource("Try It Out", comment: "Primary action button on the post drafts feature announcement.")
        case .bookmarksAnnouncement:
            return LocalizedStringResource("View Bookmarks", comment: "Primary action button on the bookmarks feature announcement.")
        case .groupChatsAnnouncement:
            return LocalizedStringResource("Open Messages", comment: "Primary action button on the group chats feature announcement.")
        case .activitySubscriptions:
            return LocalizedStringResource("Manage Alerts", comment: "Primary action button on the activity alerts feature announcement.")
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
                errorMessage = UserFacingError.message(
                    for: error,
                    action: String(localized: "save this", comment: "Action phrase when saving a feature announcement state.")
                )
                isSaving = false
            }
        }
    }

    private func navigateToFeature() {
        switch nuxID {
        case .draftsAnnouncement:
            // Drafts live in the composer, so open it on the Home tab once this sheet has closed.
            let context = sceneContext
            context.navigationManager.updateCurrentTab(0)
            context.navigationManager.tabSelection?(0)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                context.presentPostComposer()
            }
        case .bookmarksAnnouncement:
            sceneContext.navigationManager.navigate(to: .bookmarks)
        case .groupChatsAnnouncement:
            // Select the Messages tab instead of pushing a second chat split view onto this stack.
            let chatTab = AppNavigationManager.chatTabIndex
            sceneContext.navigationManager.updateCurrentTab(chatTab)
            sceneContext.navigationManager.tabSelection?(chatTab)
        case .activitySubscriptions:
            sceneContext.navigationManager.navigate(to: .activitySubscriptions)
        }
    }
}
