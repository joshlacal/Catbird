import SwiftUI
import Petrel

struct RepostOptionsView: View {
    let post: AppBskyFeedDefs.PostView
    let viewModel: ActionButtonViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                mainOptionsView
            }
            .padding()
            .navigationTitle("Repost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
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
                        logger.debug("Error toggling repost: \(error)")
                    }
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.2.squarepath")
                        .appFont(AppTextRole.title3)
                    Text("Repost")
                        .appFont(AppTextRole.headline)
                    Spacer()
                }
                .foregroundColor(.primary)
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(12)
            }

            Button {
                dismiss()

                // Slight delay to ensure the current sheet is dismissed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    appState.presentPostComposer(quotedPost: post)
                }
            } label: {
                HStack {
                    Image(systemName: "quote.bubble")
                        .appFont(AppTextRole.title3)
                    Text("Quote Post")
                        .appFont(AppTextRole.headline)
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
}
