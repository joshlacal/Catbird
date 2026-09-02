import SwiftUI

#if os(iOS)

    extension MLSConversationDetailView {
        /// Action bar shown at the bottom of a conversation detail view when the conversation
        /// is a pending inbound chat request that needs acceptance.
        struct ChatRequestActionBar: View {
            let conversationId: String
            let onAccept: () -> Void
            let onDecline: () -> Void

            @State private var isProcessing = false

            internal init(
                conversationId: String,
                onAccept: @escaping () -> Void,
                onDecline: @escaping () -> Void
            ) {
                self.conversationId = conversationId
                self.onAccept = onAccept
                self.onDecline = onDecline
            }

            var body: some View {
                VStack(spacing: 0) {
                    Divider()

                    VStack(spacing: 12) {
                        Text("This is a message request")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("Accept to continue the conversation")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 16) {
                            Button(role: .destructive) {
                                isProcessing = true
                                onDecline()
                            } label: {
                                HStack {
                                    Image(systemName: "xmark")
                                    Text("Decline")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isProcessing)

                            Button {
                                isProcessing = true
                                onAccept()
                            } label: {
                                HStack {
                                    if isProcessing {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "checkmark")
                                        Text("Accept")
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isProcessing)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                }
            }
        }
    }

#endif
