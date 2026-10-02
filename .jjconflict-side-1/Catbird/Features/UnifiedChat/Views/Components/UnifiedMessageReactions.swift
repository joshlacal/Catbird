import Petrel
import SwiftUI

/// Displays grouped reactions below a message bubble
struct UnifiedMessageReactions: View {
  let reactions: [UnifiedReaction]
  let isCurrentUser: Bool
  var onReactionTapped: ((String) -> Void)? = nil
  var onReactionLongPress: ((String) -> Void)? = nil

  @Environment(\.colorScheme) private var colorScheme

  private var groupedReactions: [String: [UnifiedReaction]] {
    Dictionary(grouping: reactions, by: { $0.emoji })
  }

  var body: some View {
    HStack(spacing: 4) {
      if isCurrentUser {
        Spacer()
      }

      ForEach(Array(groupedReactions.keys.sorted()), id: \.self) { emoji in
        let reactionsForEmoji = groupedReactions[emoji] ?? []
        let count = reactionsForEmoji.count
        let userReacted = reactionsForEmoji.contains { $0.isFromCurrentUser }

        reactionPill(emoji: emoji, count: count, userReacted: userReacted)
          .contentShape(Capsule())
          // Exclusive recognition prevents lifting a long press from also toggling.
          .gesture(
            LongPressGesture(minimumDuration: 0.35)
              .exclusively(before: TapGesture())
              .onEnded { value in
                switch value {
                case .first(true): onReactionLongPress?(emoji)
                case .second: onReactionTapped?(emoji)
                default: break
                }
              }
          )
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(emoji), \(count) reactions")
          .accessibilityValue(userReacted ? "You reacted" : "")
          .accessibilityHint("Double tap to toggle your reaction. Use Show reactors to see who reacted.")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction { onReactionTapped?(emoji) }
          .accessibilityAction(named: "Show reactors") { onReactionLongPress?(emoji) }
      }

      if let onReactionLongPress, let emoji = groupedReactions.keys.sorted().first {
        Button {
          onReactionLongPress(emoji)
        } label: {
          Image(systemName: "person.2")
            .font(.caption)
            .padding(6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Show reactors")
      }

      if !isCurrentUser {
        Spacer()
      }
    }
  }

  @ViewBuilder
  private func reactionPill(emoji: String, count: Int, userReacted: Bool) -> some View {
    HStack(spacing: 4) {
      Text(emoji)
        .font(.caption)

      if count > 1 {
        Text("\(count)")
          .font(.caption2)
          .fontWeight(.medium)
          .foregroundStyle(userReacted ? Color.accentColor : Color.secondary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(userReacted ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
        .overlay(
          RoundedRectangle(cornerRadius: 12)
            .stroke(
              userReacted ? Color.accentColor.opacity(0.5) : Color.clear,
              lineWidth: 1
            )
        )
    )
    .animation(.easeInOut(duration: 0.2), value: userReacted)
    .animation(.easeInOut(duration: 0.2), value: count)
  }
}

// MARK: - Preview

#Preview {
  VStack(spacing: 20) {
    UnifiedMessageReactions(
      reactions: [
        UnifiedReaction(messageID: "1", emoji: "👍", senderDID: "user1", isFromCurrentUser: true, reactedAt: nil),
        UnifiedReaction(messageID: "1", emoji: "👍", senderDID: "user2", isFromCurrentUser: false, reactedAt: nil),
        UnifiedReaction(messageID: "1", emoji: "❤️", senderDID: "user2", isFromCurrentUser: false, reactedAt: nil),
      ],
      isCurrentUser: false
    )

    UnifiedMessageReactions(
      reactions: [
        UnifiedReaction(messageID: "2", emoji: "😂", senderDID: "user1", isFromCurrentUser: false, reactedAt: nil),
      ],
      isCurrentUser: true
    )
  }
  .padding()
}

/// Reads the current message on every observation update, including remote removals.
/// Profile lookup stays tied to the account that opened the conversation.
@MainActor
struct UnifiedReactionDetailsSheet<Source: UnifiedChatDataSource>: View {
  let dataSource: Source
  let messageID: String
  let appState: AppState
  let accountDID: String

  @Environment(\.dismiss) private var dismiss
  @State private var profiles: [String: ReactorProfile] = [:]

  private var isActiveAccount: Bool {
    let lifecycle = AppStateManager.shared.lifecycle
    return lifecycle.appState === appState && lifecycle.userDID == accountDID
      && !appState.isTransitioningAccounts
  }

  private var reactions: [UnifiedReaction] {
    guard isActiveAccount,
          let message = dataSource.message(for: messageID),
          !message.isTombstone else { return [] }
    return message.reactions
  }

  private var groups: [(emoji: String, reactions: [UnifiedReaction])] {
    Dictionary(grouping: reactions, by: \.emoji)
      .map { emoji, values in
        var seen = Set<String>()
        return (emoji: emoji, reactions: values.filter { seen.insert($0.senderDID).inserted }
          .sorted { $0.senderDID < $1.senderDID })
      }
      .sorted { $0.emoji < $1.emoji }
  }

  private var senderDIDs: [String] { Array(Set(reactions.map(\.senderDID))).sorted() }

  var body: some View {
    NavigationStack {
      List {
        if reactions.isEmpty {
          Text("No reactions")
            .foregroundStyle(.secondary)
        }
        ForEach(groups, id: \.emoji) { group in
          Section {
            ForEach(group.reactions) { reaction in
              reactorRow(reaction)
            }
          } header: {
            Text("\(group.emoji) · \(group.reactions.count)")
          }
        }
      }
      .navigationTitle("Reactions")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .onChange(of: isActiveAccount) { _, active in
      if !active {
        profiles.removeAll()
        dismiss()
      }
    }
    .task(id: ProfileRequestID(senders: senderDIDs, client: appState.atProtoClient.map(ObjectIdentifier.init))) {
      guard !Task.isCancelled, isActiveAccount, let client = appState.atProtoClient else { return }
      let result = await Self.fetchProfiles(dids: senderDIDs, client: client)
      guard !Task.isCancelled, isActiveAccount, appState.atProtoClient === client else { return }
      profiles.merge(result) { _, new in new }
    }
  }

  private struct ProfileRequestID: Hashable {
    let senders: [String]
    let client: ObjectIdentifier?
  }

  struct ReactorProfile {
    let handle: String
    let displayName: String?
    let avatarURL: URL?
  }

  /// Resolves reactor profiles via `app.bsky.actor.getProfiles` (25 actors per request).
  /// Failed batches are skipped; those rows fall back to showing the DID.
  private static func fetchProfiles(dids: [String], client: ATProtoClient) async -> [String: ReactorProfile] {
    var result: [String: ReactorProfile] = [:]
    let batchSize = 25
    for start in stride(from: 0, to: dids.count, by: batchSize) {
      guard !Task.isCancelled else { break }
      let batch = dids[start..<min(start + batchSize, dids.count)]
      let actors = batch.compactMap { try? ATIdentifier(string: $0) }
      guard !actors.isEmpty else { continue }
      guard let (code, response) = try? await client.app.bsky.actor.getProfiles(
        input: AppBskyActorGetProfiles.Parameters(actors: actors)
      ), (200..<300).contains(code), let response else { continue }
      for profile in response.profiles {
        result[profile.did.didString()] = ReactorProfile(
          handle: profile.handle.description,
          displayName: profile.displayName,
          avatarURL: profile.avatar.flatMap { URL(string: $0.uriString()) }
        )
      }
    }
    return result
  }

  private func reactorRow(_ reaction: UnifiedReaction) -> some View {
    let profile = profiles[reaction.senderDID]
    return HStack(spacing: 12) {
      AsyncImage(url: profile?.avatarURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Image(systemName: "person.crop.circle.fill")
          .resizable().foregroundStyle(.secondary)
      }
      .frame(width: 40, height: 40)
      .clipShape(Circle())
      .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(profile?.displayName.flatMap { $0.isEmpty ? nil : $0 }
          ?? profile?.handle ?? reaction.senderDID)
        if let handle = profile?.handle {
          Text("@\(handle)").font(.subheadline).foregroundStyle(.secondary)
        }
        if reaction.isFromCurrentUser {
          Text("You").font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 4)

    }
  }
}
