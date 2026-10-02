import Foundation
import Observation
import OSLog
import Petrel

@Observable
@MainActor
final class NuxAnnouncementPresenter {
    private let logger = Logger(subsystem: "blue.catbird", category: "NuxAnnouncementPresenter")

    static let evaluationOrder: [NuxID] = [
        .bookmarksAnnouncement,
        .draftsAnnouncement,
        .groupChatsAnnouncement,
        .activitySubscriptions
    ]

    var activeAnnouncement: NuxID?
    private weak var appState: AppState?

    init(appState: AppState? = nil) {
        self.appState = appState
    }

    func configure(with appState: AppState) {
        self.appState = appState
    }

    /// Evaluates the next eligible announcement in deterministic order
    func evaluateNextAnnouncement(from preferences: Preferences?) -> NuxID? {
        guard let preferences = preferences else { return nil }

        let nuxStates = preferences.nuxStates
        let now = Date()

        for candidate in Self.evaluationOrder {
            guard let state = nuxStates.first(where: { $0.id == candidate.rawValue }) else {
                // If not present in server-provided nuxStates, the campaign is not assigned to this account
                continue
            }
            // If completed, skip
            if state.completed { continue }
            // If expired, skip
            if let expires = state.expiresAt, expires < now { continue }
            return candidate
        }

        return nil
    }

    /// Evaluates eligibility and presents the next eligible announcement if no blocking sheet is active
    func evaluateAndPresentIfNeeded(isWelcomeShowing: Bool = false, isComposerShowing: Bool = false) {
        guard !isWelcomeShowing && !isComposerShowing else {
            logger.debug("Suppressed NUX evaluation: blocking sheet active")
            return
        }

        guard activeAnnouncement == nil else {
            logger.debug("Announcement already active: \(String(describing: self.activeAnnouncement))")
            return
        }

        guard let preferences = try? appState?.preferencesManager.getLocalPreferences() else {
            logger.debug("Preferences not loaded yet; skipping NUX check")
            return
        }

        if let next = evaluateNextAnnouncement(from: preferences) {
            logger.info("Presenting NUX announcement: \(next.rawValue, privacy: .public)")
            self.activeAnnouncement = next
        }
    }

    func dismissActiveAnnouncement() {
        self.activeAnnouncement = nil
    }
}
