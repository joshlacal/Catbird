//
//  RepostHeaderView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 12/9/23.
//

import Petrel
import SwiftUI

struct RepostHeaderView: View {
    let reposter: AppBskyActorDefs.ProfileViewBasic
    @Binding var path: NavigationPath
    
    var body: some View {
        HStack (alignment: .center, spacing: 4) {
            Image(systemName: "arrow.2.squarepath")
                .foregroundColor(.secondary)
                .font(.subheadline)
            
            Text("reposted by \(reposter.displayName ?? reposter.handle.description)")
                .font(.body)
                .textScale(.secondary)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .offset(y: -2)
                .fixedSize(horizontal: true, vertical: false)

        }
        .onTapGesture {
            path.append(NavigationDestination.profile(reposter.did.didString()))
        }
        // No padding here - controlled by parent for consistency
        .padding(.leading, 3)
    }
}
