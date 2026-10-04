import SwiftUI
import Observation

/// A destination's stable category color, independent of the user's selected accent.
enum SettingsIconFamily {
    case account, privacy, notifications, feeds, moderation, media, language, appearance, accessibility, support, advanced
    var palette: AccentColorOption? {
        switch self {
        case .account, .support: .catbird
        case .privacy: .midnight
        case .notifications: .dusk
        case .feeds, .language: .aurora
        case .moderation: .lavender
        case .media: .sunrise
        case .appearance, .accessibility: .twilight
        case .advanced: nil
        }
    }
}

struct SettingsCategoryIcon: View {
    let systemImage: String
    let family: SettingsIconFamily
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var color: Color { family.palette.map { colorScheme == .dark ? $0.darkColor : $0.color } ?? .secondary }
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: DesignTokens.Size.iconMD, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: DesignTokens.Size.iconXL, height: DesignTokens.Size.iconXL)
            .background(color.opacity(contrast == .increased ? 0.22 : 0.16), in: RoundedRectangle(cornerRadius: DesignTokens.Size.radiusSM))
            .overlay { RoundedRectangle(cornerRadius: DesignTokens.Size.radiusSM).strokeBorder(color.opacity(contrast == .increased ? 0.8 : 0.45), lineWidth: contrast == .increased ? 1.5 : 0.5) }
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
                Text(title).appFont(AppTextRole.body).foregroundStyle(.primary)
                if let summary, !summary.isEmpty { Text(summary).appFont(AppTextRole.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsRequestedFocusKey: EnvironmentKey { static let defaultValue: SettingsControlID? = nil }
private extension EnvironmentValues {
    var settingsRequestedFocus: SettingsControlID? {
        get { self[SettingsRequestedFocusKey.self] }
        set { self[SettingsRequestedFocusKey.self] = newValue }
    }
}

struct SettingsFocusedForm<Content: View>: View {
    let initialFocus: SettingsControlID?
    var isReady: Bool = true
    @ViewBuilder let content: () -> Content
    @State private var requestedFocus: SettingsControlID?
    var body: some View {
        ScrollViewReader { proxy in
            Form { content() }
                .environment(\.settingsRequestedFocus, requestedFocus)
                .task(id: isReady) {
                    guard isReady, let initialFocus else { return }
                    await Task.yield()
                    proxy.scrollTo(initialFocus, anchor: .center)
                    await Task.yield()
                    requestedFocus = initialFocus
                }
        }
    }
}

private struct SettingsControlAnchor: ViewModifier {
    let control: SettingsControlID
    @Environment(\.settingsRequestedFocus) private var requested
    @AccessibilityFocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.id(control).accessibilityIdentifier(control.rawValue).accessibilityFocused($focused)
            .task(id: requested) { if requested == control { focused = true } }
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
            LabeledContent("Applies to", value: scope)
            if scope == "Current account" {
                let handle = AppStateManager.shared.authentication.getCachedProfileData(for: appState.userDID)?.handle
                Text(handle.map { "@" + $0 } ?? appState.userDID).appFont(AppTextRole.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
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
