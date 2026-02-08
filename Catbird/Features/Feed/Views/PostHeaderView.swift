import SwiftUI

//
//  PostHeaderView.swift
//  SkylineQuest
//
//  Created by Josh LaCalamito on 2/8/24.
//

struct PostHeaderView: View {
    @Environment(AppState.self) private var appState
    let displayName: String
    let handle: String
    let timeAgo: Date
    var pronouns: String? = nil
    var isVerified: Bool = false
    
    // Constants for layout
    private let profileImageSize: CGFloat = 40
    private let spacing: CGFloat = 8
    private let handleCharacterLimit: Int = 15
    
    var body: some View {
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

                        if isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.blue)
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

                Text(formatTimeAgo(from: timeAgo))
                    .appBody()
                    .foregroundStyle(.gray)
                    .accessibilityLabel(formatTimeAgo(from: timeAgo, forAccessibility: true))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

            }
            .layoutPriority(1)
            
        }
    }
    
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
    PostHeaderView(
        displayName: "Josh", 
        handle: "josh.uno", 
        timeAgo: Date()
    )
    .environment(AppStateManager.shared)
}
