import SwiftUI
import Observation

/// A destination's stable category color, independent of the user's selected accent.
enum SettingsIconFamily {
    case account, privacy, notifications, feeds, moderation, media, language, appearance, accessibility, support, advanced
    /// Fully saturated system colors; they adapt to dark mode and Increase Contrast on their own.
    var tint: Color {
        switch self {
        case .account: .blue
        case .privacy: .indigo
        case .notifications: .red
        case .feeds: .orange
        case .moderation: .green
        case .media: .pink
        case .language: .teal
        case .appearance: .purple
        case .accessibility: .blue
        case .support: .cyan
        case .advanced: .gray
        }
    }
}

/// A solid category tile with a white glyph in every theme.
struct SettingsCategoryIcon: View {
    let systemImage: String
    let family: SettingsIconFamily
    @ScaledMetric(relativeTo: .body) private var side = DesignTokens.Size.iconXL
    var body: some View {
        Image(systemName: systemImage)
            .symbolVariant(.fill)
            .font(.system(size: side * 0.56, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(family.tint, in: RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingsNavigationRow: View {
    let title: String
    var summary: String? = nil
    let systemImage: String
    let family: SettingsIconFamily
    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.base) {
            SettingsCategoryIcon(systemImage: systemImage, family: family)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                // Concrete colors: inside a Button label, hierarchical styles pick up the button tint.
                Text(title).appFont(AppTextRole.body).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                if let summary, !summary.isEmpty { Text(summary).appFont(AppTextRole.subheadline).foregroundStyle(Color.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsFocusCoordinatorKey: EnvironmentKey { static let defaultValue: SettingsFocusCoordinator? = nil }
private extension EnvironmentValues {
    var settingsFocusCoordinator: SettingsFocusCoordinator? {
        get { self[SettingsFocusCoordinatorKey.self] }
        set { self[SettingsFocusCoordinatorKey.self] = newValue }
    }
}

struct SettingsFocusedForm<Content: View>: View {
    let initialFocus: SettingsControlID?
    var isReady: Bool = true
    @ViewBuilder let content: () -> Content
    @State private var focusCoordinator = SettingsFocusCoordinator()
    var body: some View {
        let request = SettingsFocusRequest(target: initialFocus, isReady: isReady)
        ScrollViewReader { proxy in
            Form { content() }
                .environment(\.settingsFocusCoordinator, focusCoordinator)
                .task(id: request) {
                    guard !Task.isCancelled else { return }
                    focusCoordinator.begin(request)
                    guard request.isReady, request.target != nil else { return }
                    if focusCoordinator.canScroll(request) {
                        await Task.yield()
                        guard !Task.isCancelled, focusCoordinator.markScrolled(request), let target = request.target else { return }
                        proxy.scrollTo(target, anchor: .center)
                    }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    focusCoordinator.scheduleVoiceOver(request)
                }
        }
    }
}

private struct SettingsControlAnchor: ViewModifier {
    let control: SettingsControlID
    @Environment(\.settingsFocusCoordinator) private var coordinator
    @AccessibilityFocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.id(control).accessibilityIdentifier(control.rawValue).accessibilityFocused($focused)
            .task(id: coordinator?.requestedFocus) {
                guard !Task.isCancelled, coordinator?.consumeVoiceOver(for: control) == true else { return }
                focused = true
            }
    }
}

extension View {
    func settingsControl(_ control: SettingsControlID) -> some View { modifier(SettingsControlAnchor(control: control)) }
}

struct SettingsScopeSection: View {
    @Environment(AppState.self) private var appState
    var scope: String = "Current account"
    var body: some View {
        Section {
            LabeledContent("Applies to", value: appliesTo)
        }
    }

    /// The current account's handle when known, otherwise the scope label.
    private var appliesTo: String {
        guard scope == "Current account",
              let handle = AppStateManager.shared.authentication.getCachedProfileData(for: appState.userDID)?.handle else { return scope }
        return "@" + handle
    }
}

/// Lets a staged editor participate in the Settings sheet's explicit departure flow.
@MainActor @Observable
final class SettingsDraftGuard {
    var accountDID: String?
    var hasChanges = false
    var resolve: ((Bool) async -> Bool)?
}

private struct SettingsDraftGuardKey: EnvironmentKey {
    static let defaultValue: SettingsDraftGuard? = nil
}

extension EnvironmentValues {
    var settingsDraftGuard: SettingsDraftGuard? {
        get { self[SettingsDraftGuardKey.self] }
        set { self[SettingsDraftGuardKey.self] = newValue }
    }
}

@MainActor enum SettingsAccountBoundary {
    /// AppState instances survive account switches; the lifecycle is the active account authority.
    static func isCurrent(_ did: String) -> Bool {
        AppStateManager.shared.lifecycle.userDID == did
    }
    static func isCurrent(_ did: String, revision: UInt64) -> Bool {
        isCurrent(did) && AppStateManager.shared.settingsAccountContextRevision == revision
    }
}
