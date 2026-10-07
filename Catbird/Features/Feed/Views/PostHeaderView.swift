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

    private var handleText: some View {
        Text("@\(handle)")
            .appBody()
            .foregroundColor(metadataColor)
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
        let shortTimeAgo = shortTimeAgoString(from: timeAgo)
        let accessibleTimeAgo = formatTimeAgo(from: timeAgo, forAccessibility: true)
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
                                .foregroundColor(metadataColor)
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
                    ViewThatFits(in: .horizontal) {
                        handleText
                            .fixedSize()
                            .padding(.leading, spacing)
                        handleText
                            .frame(idealWidth: Self.minimumTruncatedHandleWidth, alignment: .leading)
                            .padding(.leading, spacing)
                        Color.clear
                            .frame(width: 0, height: 0)
                    }
                    .layoutPriority(0)
                } else {
                    handleText
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
                    .foregroundStyle(metadataColor)
                    .accessibilityHidden(true)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Text(shortTimeAgo)
                    .appBody()
                    .foregroundStyle(metadataColor)
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
