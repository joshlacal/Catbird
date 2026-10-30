import SwiftUI

#if os(iOS)

    extension MLSOrdinaryConversationDetailView {
        /// Action bar shown at the bottom of a conversation detail view when the conversation
        /// is a pending inbound chat request that needs acceptance. Uses the same floating
        /// Decline/Accept pair as the Message Requests sheet.
        struct ChatRequestActionBar: View {
            let conversationId: String
            let onAccept: () async -> Void
            let onDecline: () async -> Void

            @State private var inFlight: MessageRequestDecision?

            internal init(
                conversationId: String,
                onAccept: @escaping () async -> Void,
                onDecline: @escaping () async -> Void
            ) {
                self.conversationId = conversationId
                self.onAccept = onAccept
                self.onDecline = onDecline
            }

            var body: some View {
                RequestDecisionBar(
                    inFlight: inFlight,
                    onAccept: { run(.accept, onAccept) },
                    onDecline: { run(.decline, onDecline) }
                ) {
                    VStack(spacing: 2) {
                        Text("This is a message request")
                            .font(.subheadline.weight(.semibold))
                        Text("Accept to continue the conversation")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }
            }

            private func run(_ decision: MessageRequestDecision, _ action: @escaping () async -> Void) {
                guard inFlight == nil else { return }
                inFlight = decision
                Task { @MainActor in
                    defer { inFlight = nil }
                    await action()
                }
            }
        }
    }

#endif
