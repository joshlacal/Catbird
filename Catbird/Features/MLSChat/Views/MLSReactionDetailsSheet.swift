//
//  MLSReactionDetailsSheet.swift
//  Catbird
//
//  Sheet view showing who reacted to a message, grouped by emoji
//

import OSLog
import SwiftUI

//#if os(iOS)

  /// Sheet displaying reaction details grouped by emoji with reactor profiles
  struct MLSReactionDetailsSheet: View {
    let reactions: [MLSMessageReaction]
    let participantProfiles: [String: MLSProfileEnricher.ProfileData]
    let currentUserDID: String?
    let onAddReaction: (String) -> Void  // emoji
    let onRemoveReaction: (String) -> Void  // emoji

    @Environment(\.dismiss) private var dismiss

    private let logger = Logger(subsystem: "blue.catbird", category: "ReactionDetails")

    var body: some View {
      NavigationStack {
        List {
          ForEach(groupedReactions, id: \.emoji) { group in
            Section {
              ForEach(group.reactors, id: \.did) { reactor in
                reactorRow(reactor: reactor, emoji: group.emoji)
              }
            } header: {
              HStack(spacing: 8) {
                Text(group.emoji)
                  .font(.title2)
                Text("\(group.reactors.count)")
                  .font(.subheadline)
                  .foregroundColor(.secondary)
              }
            }
          }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Reactions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
              dismiss()
            }
          }
        }
      }
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }

    // MARK: - Grouped Data

    private struct ReactorInfo {
      let did: String
      let displayName: String?
      let handle: String?
      let avatarURL: URL?
      let isCurrentUser: Bool
    }

    private struct ReactionGroup {
      let emoji: String
      let reactors: [ReactorInfo]
    }

    private var groupedReactions: [ReactionGroup] {
      let grouped = Dictionary(grouping: reactions) { $0.reaction }

      return grouped.map { emoji, reactions in
        let reactors = reactions.map { reaction -> ReactorInfo in
          let canonicalDID = MLSProfileEnricher.canonicalDID(reaction.senderDID)
          let profile = participantProfiles[canonicalDID]
          return ReactorInfo(
            did: reaction.senderDID,
            displayName: profile?.displayName,
            handle: profile?.handle,
            avatarURL: profile?.avatarURL,
            isCurrentUser: reaction.senderDID == currentUserDID
          )
        }
        return ReactionGroup(emoji: emoji, reactors: reactors)
      }
      .sorted { $0.reactors.count > $1.reactors.count }
    }

    // MARK: - Reactor Row

    @ViewBuilder
    private func reactorRow(reactor: ReactorInfo, emoji: String) -> some View {
      HStack(spacing: 12) {
        // Avatar
        AsyncImage(url: reactor.avatarURL) { phase in
          switch phase {
          case .empty:
            Circle()
              .fill(Color.gray.opacity(0.2))
              .frame(width: 40, height: 40)
          case .success(let image):
            image
              .resizable()
              .aspectRatio(contentMode: .fill)
              .frame(width: 40, height: 40)
              .clipShape(Circle())
          case .failure:
            Circle()
              .fill(Color.gray.opacity(0.2))
              .overlay {
                Image(systemName: "person.fill")
                  .foregroundColor(.gray)
              }
              .frame(width: 40, height: 40)
          @unknown default:
            Circle()
              .fill(Color.gray.opacity(0.2))
              .frame(width: 40, height: 40)
          }
        }

        // Name/Handle
        VStack(alignment: .leading, spacing: 2) {
          if let displayName = reactor.displayName, !displayName.isEmpty {
            Text(displayName)
              .font(.body)
              .fontWeight(.medium)
          }

          if let handle = reactor.handle {
            Text("@\(handle)")
              .font(.subheadline)
              .foregroundColor(.secondary)
          } else {
            // Fallback to showing truncated DID
            Text(truncatedDID(reactor.did))
              .font(.subheadline)
              .foregroundColor(.secondary)
          }
        }

        Spacer()

        // Current user indicator with toggle action
        if reactor.isCurrentUser {
          Button {
            onRemoveReaction(emoji)
            // Don't dismiss - let UI update show the change
          } label: {
            Text("Remove")
              .font(.caption)
              .foregroundColor(.red)
          }
          .buttonStyle(.bordered)
          .tint(.red)
        }
      }
      .padding(.vertical, 4)
    }

    private func truncatedDID(_ did: String) -> String {
      if did.count > 24 {
        return String(did.prefix(12)) + "..." + String(did.suffix(8))
      }
      return did
    }
  }

//  // MARK: - Preview
//
//  #Preview {
//    MLSReactionDetailsSheet(
//      reactions: [
//        MLSMessageReaction(messageId: "1", reaction: "👍", senderDID: "did:plc:user1"),
//        MLSMessageReaction(messageId: "1", reaction: "👍", senderDID: "did:plc:user2"),
//        MLSMessageReaction(messageId: "1", reaction: "👍", senderDID: "did:plc:currentuser"),
//        MLSMessageReaction(messageId: "1", reaction: "❤️", senderDID: "did:plc:user1"),
//        MLSMessageReaction(messageId: "1", reaction: "😂", senderDID: "did:plc:user3"),
//      ],
//      participantProfiles: [
//        "did:plc:user1": MLSProfileEnricher.ProfileData.preview(
//          did: "did:plc:user1", handle: "alice.bsky.social", displayName: "Alice"),
//        "did:plc:user2": MLSProfileEnricher.ProfileData.preview(
//          did: "did:plc:user2", handle: "bob.bsky.social", displayName: "Bob"),
//        "did:plc:currentuser": MLSProfileEnricher.ProfileData.preview(
//          did: "did:plc:currentuser", handle: "me.bsky.social", displayName: "Me"),
//      ],
//      currentUserDID: "did:plc:currentuser",
//      onAddReaction: { _ in },
//      onRemoveReaction: { _ in }
//    )
//  }
//
//  // MARK: - Preview Helper
//
//  extension MLSProfileEnricher.ProfileData {
//    static func preview(did: String, handle: String, displayName: String?)
//      -> MLSProfileEnricher.ProfileData
//    {
//      // Create a mock profile for previews
//      PreviewProfileData(did: did, handle: handle, displayName: displayName, avatarURL: nil)
//    }
//  }
//
//  private struct PreviewProfileData {
//    let did: String
//    let handle: String
//    let displayName: String?
//    let avatarURL: URL?
//  }
//
//#endif
