import SwiftUI
import Petrel

struct RepostOptionsView: View {
    let post: AppBskyFeedDefs.PostView
    let viewModel: ActionButtonViewModel
        
    @Environment(\.dismiss) private var dismiss
    @State private var quoteText = ""
    @State private var isComposing = false
    @State private var isSubmitting = false
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                if !isComposing {
                    mainOptionsView
                } else {
                    quoteComposerView
                }
            }
            .padding()
            .navigationTitle("Repost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isComposing {
                        Button("Back") {
                            isComposing = false
                        }
                    } else {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
                
                if isComposing {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Post") {
                            // Haptic feedback immediately
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            
                            // Prevent double submissions
                            isSubmitting = true
                            
                            // Dismiss the sheet
                            dismiss()
                            
                            // Perform network operation
                            Task {
                                do {
                                    let success = try await viewModel.createQuotePost(text: quoteText)
                                    if !success {
                                        print("Failed to create quote post")
                                    }
                                } catch {
                                    print("Error posting quote: \(error)")
                                }
                                isSubmitting = false
                            }
                        }
                        .disabled(quoteText.isEmpty || isSubmitting)
                    }
                }
            }
        }
    }
    
    private var mainOptionsView: some View {
        VStack(spacing: 20) {
            Button {
                // Haptic feedback immediately
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                
                // Dismiss the sheet
                dismiss()
                
                // Just perform the network operation - no direct UI update
                Task {
                    do {
                        try await viewModel.toggleRepost()
                    } catch {
                        print("Error toggling repost: \(error)")
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.title3)
                    Text("Repost")
                        .font(.headline)
                    Spacer()
                }
                .foregroundColor(.primary)
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(12)
            }
            
            Button {
                isComposing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isTextFieldFocused = true
                }
            } label: {
                HStack {
                    Image(systemName: "quote.bubble")
                        .font(.title3)
                    Text("Quote Post")
                        .font(.headline)
                    Spacer()
                }
                .foregroundColor(.primary)
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .opacity(post.viewer?.embeddingDisabled ?? false ? 0.3 : 1)
            }
            .disabled(post.viewer?.embeddingDisabled ?? false)

        }
        .padding(.horizontal)
    }
    
    // The quoteComposerView can remain the same
    private var quoteComposerView: some View {
        // Your existing implementation
        VStack(alignment: .leading, spacing: 16) {
            TextEditor(text: $quoteText)
                .focused($isTextFieldFocused)
                .frame(height: 150)
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
            
            VStack(alignment: .leading, spacing: 8) {
                Text(post.author.displayName ?? post.author.handle.description)
                    .font(.headline)
                Text(post.record.textRepresentation)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(8)
            
            Spacer()
        }
        .padding(.horizontal)
    }
}
