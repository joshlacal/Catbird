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
    let imageData: Data?
    @State private var editedText: String
    let maxLength: Int = 1000
    let onSave: (String, UUID) -> Void

    @State private var remainingChars: Int
    @State private var showingOCRSelection = false

    init(altText: String, image: Image, imageId: UUID, imageData: Data? = nil, onSave: @escaping (String, UUID) -> Void) {
        self.image = image
        self.imageId = imageId
        self.imageData = imageData
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

                    // OCR button (only show if we have image data)
                    if imageData != nil {
                        Button(action: {
                            showingOCRSelection = true
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text.viewfinder")
                                    .appFont(AppTextRole.subheadline)
                                Text("Select Text from Image")
                                    .appFont(AppTextRole.subheadline)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Select text from image using OCR")
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                
                // Text editor
                VStack(alignment: .trailing) {
                    TextField("Describe this content...", text: $editedText, axis: .vertical)
                        .padding()
                        .background(Color(platformColor: PlatformColor.platformSystemGray6))
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
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
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
            .sheet(isPresented: $showingOCRSelection) {
                if let imageData = imageData {
                    if #available(iOS 26.0, macOS 26.0, *) {
                        OCRTextSelectionView(
                            image: image,
                            imageData: imageData,
                            onTextSelected: { selectedText in
                                insertOCRText(selectedText)
                            }
                        )
                    } else {
                        OCRTextSelectionViewLegacy(
                            image: image,
                            imageData: imageData,
                            onTextSelected: { selectedText in
                                insertOCRText(selectedText)
                            }
                        )
                    }
                }
            }
        }
    }

    private func insertOCRText(_ text: String) {
        // Append with a space if there's existing text
        let separator = editedText.isEmpty ? "" : " "
        let newText = editedText + separator + text

        // Truncate if over limit
        if newText.count > maxLength {
            editedText = String(newText.prefix(maxLength))
        } else {
            editedText = newText
        }

        // Update remaining chars
        remainingChars = maxLength - editedText.count
    }
}

#Preview {
    @ObservationIgnored @Previewable @ObservationIgnored @Environment(AppState.self) var appState
    AltTextEditorView(
        altText: "A sample alt text",
        image: Image(systemName: "photo"),
        imageId: UUID(),
        onSave: { _, _ in }
    )
}
