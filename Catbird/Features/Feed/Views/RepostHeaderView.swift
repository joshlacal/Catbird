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
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "arrow.2.squarepath")
                .foregroundColor(.secondary)
                .appFont(AppTextRole.subheadline)
            
            Text("reposted by \(reposter.displayName ?? reposter.handle.description)")
                                .appFont(AppTextRole.body)
                .textScale(.secondary)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .allowsTightening(true)
                .offset(y: -2)
                .fixedSize(horizontal: false, vertical: true)

        }
        .onTapGesture {
            path.append(NavigationDestination.profile(reposter.did.didString()))
        }
        .padding(.leading, 3)
    }
}
