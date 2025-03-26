//
//  EditProfileView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/5/24.
//

import SwiftUI
import Petrel
import NukeUI

struct EditProfileView: View {
    @Environment(AppState.self) private var appState
    @State private var displayName: String = ""
    @State private var description: String = ""
    @Binding var isPresented: Bool
    var viewModel: ProfileViewModel
    
    init(isPresented: Binding<Bool>, viewModel: ProfileViewModel) {
        self._isPresented = isPresented
        self.viewModel = viewModel
        _displayName = State(initialValue: viewModel.profile?.displayName ?? "")
        _description = State(initialValue: viewModel.profile?.description ?? "")
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Profile Information")) {
                    TextField("Display Name", text: $displayName)
                    TextEditor(text: $description)
                        .frame(height: 100)
                }
                
                Button("Save Changes") {
                    Task {
                        do {
                            try await viewModel.updateProfile(displayName: displayName, description: description)
                            isPresented = false
                        } catch {
                            print("Error updating profile: \(error)")
                        }
                    }
                }
            }
            .navigationTitle("Edit Profile")
#if os(iOS)

            .navigationBarItems(trailing: Button("Cancel") {
                isPresented = false
            })
#endif

        }
    }
}
