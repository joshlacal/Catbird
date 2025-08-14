//
//  AltTextEditorView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/24/25.
//

import SwiftUI

/// A view for editing the alt text of an image or video
struct AltTextEditorView: View {
    @Environment(\.dismiss) private var dismiss
    
    let image: Image
    let imageId: UUID
    @State private var editedText: String
    let maxLength: Int = 1000
    let onSave: (String, UUID) -> Void
    
    @State private var remainingChars: Int
    
    init(altText: String, image: Image, imageId: UUID, onSave: @escaping (String, UUID) -> Void) {
        self.image = image
        self.imageId = imageId
        self._editedText = State(initialValue: altText)
        self.onSave = onSave
        self._remainingChars = State(initialValue: 1000 - altText.count)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Image preview
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 220)
                    .cornerRadius(12)
                    .padding(.horizontal)
                
                // Alt text guidance
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a description for people who can't see this content")
                        .appFont(AppTextRole.headline)
                        .foregroundStyle(.primary)
                    
                    Text("Good descriptions are concise, accurate, and focus on what's important in the image or video.")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                
                // Text editor
                VStack(alignment: .trailing) {
                    TextField("Describe this content...", text: $editedText, axis: .vertical)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                        .frame(minHeight: 100, maxHeight: 150)
                        .onChange(of: editedText) { _, newValue in
                            remainingChars = maxLength - newValue.count
                            
                            // Truncate if over limit
                            if newValue.count > maxLength {
                                editedText = String(newValue.prefix(maxLength))
                            }
                        }
                    
                    // Character count
                    Text("\(remainingChars) characters remaining")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(remainingChars < 50 ? .orange : .secondary)
                        .padding(.trailing, 4)
                }
                .padding(.horizontal)
                
                Spacer()
            }
            .padding(.vertical)
            .navigationTitle("Edit Description")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(editedText, imageId)
                        dismiss()
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Description editor")
        }
    }
}

#Preview {
    AltTextEditorView(
        altText: "A sample alt text",
        image: Image(systemName: "photo"),
        imageId: UUID(),
        onSave: { _, _ in }
    )
}
