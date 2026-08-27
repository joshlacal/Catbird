//
//  StarterPackDetailsStep.swift
//  Catbird
//
//  Created for Bluesky social app parity (WS-H / G57).
//

import SwiftUI
import Petrel

struct StarterPackDetailsStep: View {
    @Binding var draft: StarterPackDraft
    @FocusState private var isNameFocused: Bool
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Name")
                            .appFont(AppTextRole.headline)
                        Spacer()
                        Text("\(draft.trimmedName.count)/\(StarterPackDraft.maxNameLength)")
                            .appFont(AppTextRole.caption)
                            .foregroundColor(draft.trimmedName.count > StarterPackDraft.maxNameLength ? .red : .secondary)
                    }
                    
                    TextField("e.g., iOS Developers, Artists, Friends", text: $draft.name)
                        .focused($isNameFocused)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .onChange(of: draft.name) { _, newValue in
                            if newValue.count > StarterPackDraft.maxNameLength {
                                draft.name = String(newValue.prefix(StarterPackDraft.maxNameLength))
                            }
                        }
                    
                    if draft.trimmedName.isEmpty {
                        Text("A name is required.")
                            .appFont(AppTextRole.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Pack Details")
            } footer: {
                Text("Give your starter pack a descriptive name that helps people find what they're looking for.")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Description")
                            .appFont(AppTextRole.headline)
                        Spacer()
                        Text("\(draft.description.count)/\(StarterPackDraft.maxDescriptionLength)")
                            .appFont(AppTextRole.caption)
                            .foregroundColor(draft.description.count > StarterPackDraft.maxDescriptionLength ? .red : .secondary)
                    }
                    
                    TextEditor(text: $draft.description)
                        .frame(minHeight: 100)
                        .onChange(of: draft.description) { _, newValue in
                            if newValue.count > StarterPackDraft.maxDescriptionLength {
                                draft.description = String(newValue.prefix(StarterPackDraft.maxDescriptionLength))
                            }
                        }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Description (Optional)")
            } footer: {
                Text("Explain who is in this pack and why someone should follow them.")
            }
        }
        .onAppear {
            if draft.name.isEmpty {
                isNameFocused = true
            }
        }
    }
}
