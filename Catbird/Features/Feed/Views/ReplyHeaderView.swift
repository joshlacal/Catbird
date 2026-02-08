//
//  ReplyHeaderView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/8/24.
//

import SwiftUI

struct ReplyHeaderView: View {
    let displayName: String
    let handle: String
    let timeAgo: String
    // Constants for layout
    private let profileImageSize: CGFloat = 40
    private let spacing: CGFloat = 8
    private let handleCharacterLimit: Int = 15

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // Main Content
            HStack(spacing: spacing) {
                // DisplayName with potential truncation
                Text(displayName)
                    .appFont(AppTextRole.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                // Handle with conditional visibility and truncation
                Text("@\(handle)")
                                    .appFont(AppTextRole.body)
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
            }
            .layoutPriority(1) // Gives priority to this HStack

            // Separator and Time
            HStack(spacing: spacing) {
                Text("·")
                    .foregroundStyle(.gray)
                Text(timeAgo)
                                    .appFont(AppTextRole.body)
                    .foregroundStyle(.gray)
            }
            .layoutPriority(1)

        }
    }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
    ReplyHeaderView(displayName: "Josh", handle: "josh.uno", timeAgo: "2m")
}
