//
//  MLSSystemMessageView.swift
//  Catbird
//
//  SwiftUI view for displaying system messages in MLS conversations
//

import SwiftUI

#if os(iOS)

/// View component for displaying system messages (membership changes, etc.)
/// Displayed centered in the chat with a minimal, unobtrusive style
struct MLSSystemMessageView: View {
  let systemMessage: MLSSystemMessage
  let profiles: [String: MLSProfileEnricher.ProfileData]
  let currentUserDID: String?

  // MARK: - Body

  var body: some View {
    HStack {
      Spacer()

      Text(systemMessage.displayText(profiles: profiles, currentUserDID: currentUserDID ?? ""))
        .font(.footnote)
        .foregroundColor(.secondary)
        .padding(.horizontal, DesignTokens.Spacing.base)
        .padding(.vertical, DesignTokens.Spacing.xs)

      Spacer()
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("System message: \(systemMessage.displayText(profiles: profiles, currentUserDID: currentUserDID ?? ""))")
  }
}

// MARK: - Preview

//#Preview {
//  VStack(spacing: 20) {
//    // Member joined
//    MLSSystemMessageView(
//      systemMessage: MLSSystemMessage(
//        id: "1",
//        conversationId: "test",
//        type: .memberJoined,
//        timestamp: Date(),
//        actorDID: nil,
//        targetDID: "did:plc:alice123",
//        infoText: nil
//      ),
//      profiles: [
//        "did:plc:alice123": MLSProfileEnricher.ProfileData(
//          did: "did:plc:alice123",
//          handle: "alice.bsky.social",
//          displayName: "Alice",
//          avatarURL: nil,
//          lastUpdated: Date()
//        )
//      ],
//      currentUserDID: "did:plc:currentuser"
//    )
//
//    // Member removed
//    MLSSystemMessageView(
//      systemMessage: MLSSystemMessage(
//        id: "2",
//        conversationId: "test",
//        type: .memberKicked,
//        timestamp: Date(),
//        actorDID: "did:plc:admin123",
//        targetDID: "did:plc:bob456",
//        infoText: nil
//      ),
//      profiles: [
//        "did:plc:admin123": MLSProfileEnricher.ProfileData(
//          did: "did:plc:admin123",
//          handle: "admin.bsky.social",
//          displayName: "Admin",
//          avatarURL: nil,
//          lastUpdated: Date()
//        ),
//        "did:plc:bob456": MLSProfileEnricher.ProfileData(
//          did: "did:plc:bob456",
//          handle: "bob.bsky.social",
//          displayName: "Bob",
//          avatarURL: nil,
//          lastUpdated: Date()
//        )
//      ],
//      currentUserDID: "did:plc:currentuser"
//    )
//
//    // Current user joined
//    MLSSystemMessageView(
//      systemMessage: MLSSystemMessage(
//        id: "3",
//        conversationId: "test",
//        type: .memberJoined,
//        timestamp: Date(),
//        actorDID: nil,
//        targetDID: "did:plc:currentuser",
//        infoText: nil
//      ),
//      profiles: [:],
//      currentUserDID: "did:plc:currentuser"
//    )
//
//    // Device added
//    MLSSystemMessageView(
//      systemMessage: MLSSystemMessage(
//        id: "4",
//        conversationId: "test",
//        type: .deviceAdded,
//        timestamp: Date(),
//        actorDID: nil,
//        targetDID: "did:plc:alice123",
//        infoText: "iPhone 16 Pro"
//      ),
//      profiles: [
//        "did:plc:alice123": MLSProfileEnricher.ProfileData(
//          did: "did:plc:alice123",
//          handle: "alice.bsky.social",
//          displayName: "Alice",
//          avatarURL: nil,
//          lastUpdated: Date()
//        )
//      ],
//      currentUserDID: "did:plc:currentuser"
//    )
//
//    // Info message
//    MLSSystemMessageView(
//      systemMessage: MLSSystemMessage(
//        id: "5",
//        conversationId: "test",
//        type: .infoMessage,
//        timestamp: Date(),
//        actorDID: nil,
//        targetDID: nil,
//        infoText: "Encryption keys have been updated"
//      ),
//      profiles: [:],
//      currentUserDID: "did:plc:currentuser"
//    )
//  }
//  .padding()
//}
//
#endif
