import SwiftUI

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
    @Environment(\.accessibilityContrast) private var contrast
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
                Text(title).foregroundStyle(.primary)
                if let summary, !summary.isEmpty { Text(summary).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
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
            if scope == "Current account" { Text(appState.userDID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}
