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

    init(
        displayName: String,
        handle: String,
        timeAgo: Date,
        pronouns: String? = nil,
        verificationKind: VerificationBadgeKind? = nil
    ) {
        self.displayName = displayName
        self.handle = handle
        self.timeAgo = timeAgo
        self.pronouns = pronouns
        self.verificationKind = verificationKind
    }
    
    // Constants for layout
    private let spacing: CGFloat = 8
    
    var body: some View {
        let shortTimeAgo = shortTimeAgoString(from: timeAgo)
        let accessibleTimeAgo = formatTimeAgo(from: timeAgo, forAccessibility: true)

        HStack(alignment: .top) {
            // Main Content
            HStack(alignment: .top, spacing: spacing) {
                // DisplayName with potential truncation
                if displayName != "" {
                    HStack(spacing: 4) {
                        Text(displayName)
                            .appHeadline()
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if let verificationKind {
                            VerificationBadgeView(kind: verificationKind)
                                .font(.caption)
                        }
                        
                        if let pronouns, !pronouns.isEmpty {
                            Text("\(pronouns)")
                                .appBody()
                                .foregroundColor(.gray)
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
                // Handle with conditional visibility and truncation
                HStack(spacing: 4) {
                    Text("@\(handle)")
                        .appBody()
                        .foregroundColor(.gray)
                        .lineLimit(1)
                        .truncationMode(.tail)

                }
                .layoutPriority(0)
            }
            .layoutPriority(1) // Gives priority to this HStack
                               // Separator and Time
            HStack(alignment: .top, spacing: spacing) {
                Text("·")
                    .foregroundStyle(.gray)
                    .accessibilityHidden(true)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Text(shortTimeAgo)
                    .appBody()
                    .foregroundStyle(.gray)
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

