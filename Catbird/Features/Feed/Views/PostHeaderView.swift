import SwiftUI

//
//  PostHeaderView.swift
//  SkylineQuest
//
//  Created by Josh LaCalamito on 2/8/24.
//

struct PostHeaderView: View {
    let displayName: String
    let handle: String
    let timeAgo: Date
    var pronouns: String? = nil
    var verificationKind: VerificationBadgeKind? = nil
    var isAutomated = false

    @Environment(AppState.self) private var appState: AppState?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    init(
        displayName: String,
        handle: String,
        timeAgo: Date,
        pronouns: String? = nil,
        verificationKind: VerificationBadgeKind? = nil,
        isAutomated: Bool = false
    ) {
        self.displayName = displayName
        self.handle = handle
        self.timeAgo = timeAgo
        self.pronouns = pronouns
        self.verificationKind = verificationKind
        self.isAutomated = isAutomated
    }
    
    // Constants for layout
    private let spacing: CGFloat = 8
    /// Narrowest width at which a truncated handle still reads as one ("@abc…").
    private static let minimumTruncatedHandleWidth: CGFloat = 56

    private func handleText(color: Color) -> some View {
        Text("@\(handle)")
            .appBody()
            .foregroundColor(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Matches the theme-aware secondary text used by "in reply to" and the menu glyph.
    private var metadataColor: Color {
        guard let appState else { return .secondary }
        return Color.adaptiveText(
            appState: appState, themeManager: appState.themeManager,
            style: .secondary, currentScheme: colorScheme)
    }
    
    var body: some View {
        standardHeader
    }

    @ViewBuilder
    private var standardHeader: some View {
        let metaColor = metadataColor
        let shortTimeAgo = shortTimeAgoString(from: timeAgo)
        let accessibleTimeAgo = voiceOverEnabled ? formatTimeAgo(from: timeAgo, forAccessibility: true) : shortTimeAgo
        let hasDisplayName = !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        HStack(alignment: .top) {
            // Main Content. Spacing lives on the handle and badge so a hidden
            // handle leaves no gap before the time.
            HStack(alignment: .top, spacing: 0) {
                // DisplayName with potential truncation
                if hasDisplayName {
                    HStack(spacing: 4) {
                        Text(displayName)
                            .appHeadline()
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let verificationKind {
                            VerificationBadgeView(kind: verificationKind)
                                .font(.caption)
                                .fixedSize()
                                .layoutPriority(1)
                        }
                        if isAutomated {
                            AutomationBadgeView()
                                .layoutPriority(1)
                        }
                        
                        if let pronouns, !pronouns.isEmpty {
                            Text("\(pronouns)")
                                .appBody()
                                .foregroundColor(metaColor)
                                .lineLimit(1)
                                .opacity(0.9)
                                .textScale(.secondary)
                                .padding(1)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.secondary.opacity(0.1))
                                )

                        }

                    }
                    .layoutPriority(1)
                }
                // The handle takes whatever the name and time leave. Beside a display
                // name it shows in full, truncated if at least a few characters fit,
                // or not at all, rather than as a stray "@" or "(".
                if hasDisplayName {
                    HandleFitLayout(minimumWidth: Self.minimumTruncatedHandleWidth + spacing) {
                        handleText(color: metaColor)
                            .padding(.leading, spacing)
                    }
                    .clipShape(HorizontalClipShape())
                    .layoutPriority(0)
                } else {
                    handleText(color: metaColor)
                        .layoutPriority(0)
                }
                if !hasDisplayName && isAutomated {
                    AutomationBadgeView()
                        .padding(.leading, spacing)
                        .layoutPriority(1)
                }
            }
            .layoutPriority(1) // Gives priority to this HStack
                               // Separator and Time
            HStack(alignment: .top, spacing: spacing) {
                Text("·")
                    // At Tight the separator's line takes the constant line height like the time's.
                    .appLineSpacing()
                    .foregroundStyle(metaColor)
                    .accessibilityHidden(true)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Text(shortTimeAgo)
                    .appBody()
                    .foregroundStyle(metaColor)
                    .accessibilityLabel(accessibleTimeAgo)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            .layoutPriority(1)
            
        }
    }
    
}

#Preview {
  AsyncPreviewContent { appState in
    PostHeaderView(
            displayName: "Josh", 
            handle: "josh.uno", 
            timeAgo: Date()
        )
        .environment(AppStateManager.shared)
  }
}

/// Sizes the handle beside a display name in one measurement: its full width when
/// that fits, the offered width when at least `minimumWidth` fits (the text
/// truncates), and zero otherwise (clipped away by the caller). Feed rows lay
/// this out on every scroll, where `ViewThatFits` built and measured three candidates.
private struct HandleFitLayout: Layout {
    let minimumWidth: CGFloat

    func makeCache(subviews: Subviews) -> CGSize {
        subviews.first?.sizeThatFits(.unspecified) ?? .zero
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout CGSize) -> CGSize {
        let ideal = cache
        guard let available = proposal.width else { return ideal }
        if available >= ideal.width { return ideal }
        if available >= minimumWidth { return CGSize(width: available, height: ideal.height) }
        return .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout CGSize) {
        guard let handle = subviews.first else { return }
        handle.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: cache.height))
    }

    func updateCache(_ cache: inout CGSize, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }
}

/// Clips to the frame's width only. A handle squeezed to nothing disappears, while ink above and
/// below its line stays: at Tight (`AppLineHeightModifier`) the descenders of "g", "j", "p", "y"
/// and "@" draw below the line's frame.
private struct HorizontalClipShape: Shape {
    func path(in rect: CGRect) -> Path {
        // A line's ink reaches at most one line height past its frame.
        Path(rect.insetBy(dx: 0, dy: -rect.height))
    }
}
