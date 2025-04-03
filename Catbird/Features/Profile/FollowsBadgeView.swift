//
//  FollowsBadgeView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 4/2/25.
//

import SwiftUI

struct FollowsBadgeView: View {
    var body: some View {
        Text("Follows you")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.1))
            )
    }
}
