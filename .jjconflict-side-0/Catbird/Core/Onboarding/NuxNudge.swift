import SwiftUI

enum NuxID: String, CaseIterable, Sendable, Identifiable {
    case draftsAnnouncement = "DraftsAnnouncement"
    case bookmarksAnnouncement = "BookmarksAnnouncement"
    case groupChatsAnnouncement = "GroupChatsAnnouncement"
    case activitySubscriptions = "ActivitySubscriptions"

    var id: String { rawValue }
}

struct NuxNudge: View {
    init() {}
    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color.accentColor, Color.purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 8, height: 8)
            .shadow(color: Color.accentColor.opacity(0.4), radius: 2, x: 0, y: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct NuxNudgeModifier: ViewModifier {
    let id: NuxID
    @Environment(AppState.self) private var appState

    init(id: NuxID) {
        self.id = id
    }

    static func isNudgeEligible(id: NuxID, from preferences: Preferences?, forDID userDID: String) -> Bool {
        guard !userDID.isEmpty, let preferences else { return false }
        guard preferences.accountDID.isEmpty || preferences.accountDID == userDID else { return false }
        guard let nux = preferences.nuxStates.first(where: { $0.id == id.rawValue }) else {
            // NUX state is evaluated only after real server preferences load and never synthesized when absent
            return false
        }
        if nux.completed {
            return false
        }
        if let expires = nux.expiresAt, expires < Date() {
            return false
        }
        return true
    }

    private var shouldShowNudge: Bool {
        let prefs = try? appState.preferencesManager.getLocalPreferences()
        return Self.isNudgeEligible(id: id, from: prefs, forDID: appState.userDID)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if shouldShowNudge {
                    NuxNudge()
                        .offset(x: 2, y: -2)
                }
            }
    }
}

extension View {
    func nuxNudge(id: NuxID) -> some View {
        modifier(NuxNudgeModifier(id: id))
    }

    @ViewBuilder
    func nuxNudge(for destination: NavigationDestination) -> some View {
        if let nuxID = NavigationHandler.nuxIDForDestination(destination) {
            self.nuxNudge(id: nuxID)
        } else {
            self
        }
    }
}
