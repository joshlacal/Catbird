//
//  ProfileView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/20/26.
//

import SwiftUI
import Petrel

struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @State private var handle: String = ""
    
    var body: some View {
        Text(handle)
            .task {
                handle = await appState.client.getCurrentAccount()?.handle ?? ""
            }
    }
}

#Preview {
    ProfileView()
        .previewWithAuthenticatedState()
}
