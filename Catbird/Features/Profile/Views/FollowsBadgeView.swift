//
//  FollowsBadgeView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 4/2/25.
//

import SwiftUI

struct FollowsBadgeView: View {
    var body: some View {
        Text("Follows you", comment: "Badge shown on a profile when that account follows the signed-in user.")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
            )
    }
}

#Preview("FollowsBadgeView") {
  FollowsBadgeView()
    .padding()
    .previewWithMockEnvironment()
}
