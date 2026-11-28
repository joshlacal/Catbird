//
//  CatbirdCatalogSecondarySurfaces.swift
//  Catbird
//
//  Offline mocked catalog surfaces for Chat, Composer, and Ask Catbird.
//

#if DEBUG
import Petrel
import SwiftUI

// MARK: - Chat & E2EE Surface

struct CatalogChatSurface: View {
  let appState: AppState
  @Environment(\.colorScheme) private var colorScheme
  @State private var draftMessage = ""

  var body: some View {
    let convos = PreviewFixtures.chatConvos?.convos ?? []
    let sharedPost = PreviewFixtures.post(.textShort)

    NavigationStack {
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: Space.lg) {
            CatbirdNotice(
              tone: .info,
              title: Text(verbatim: "End-to-End Encrypted"),
              message: Text(verbatim: "MLS epoch 14 verified across 3 group devices.")
            )

            if !convos.isEmpty {
              inboxSection(convos: convos)
            }

            transcriptSection(sharedPost: sharedPost)
          }
          .padding(Space.screenMargin)
        }

        composerBar
      }
      .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
      .navigationTitle(Text(verbatim: "Messages"))
    }
    .accessibilityIdentifier("catalog.surface.content.chat")
  }

  private func inboxSection(convos: [ChatBskyConvoDefs.ConvoView]) -> some View {
    VStack(alignment: .leading, spacing: Space.sm) {
      Text(verbatim: "Inbox")
        .appFont(AppTextRole.headline)
      ForEach(convos, id: \.id) { convo in
        ConversationRow(convo: convo, currentUserDID: appState.userDID)
          .padding(Space.md)
          .catbirdCard(.panel)
      }
    }
  }

  private func transcriptSection(sharedPost: AppBskyFeedDefs.PostView?) -> some View {
    VStack(alignment: .leading, spacing: Space.md) {
      Text(verbatim: "Group Transcript")
        .appFont(AppTextRole.headline)

      incomingBubble(
        sender: "Maya Chen",
        text: "Did everyone confirm the new Catbird typography scale on True Black?"
      )
      outgoingBubble(
        text: "Yes — checked Light, Dim, True Black, and AX3 on the catalog wall."
      )

      if let sharedPost {
        CompactPostCard(
          avatarURL: sharedPost.author.finalAvatarURL(),
          displayName: sharedPost.author.displayName ?? sharedPost.author.handle.description,
          handle: sharedPost.author.handle.description,
          text: "Shared fixture post preview rendered inside an encrypted transcript."
        )
      }
    }
  }

  private var composerBar: some View {
    HStack(spacing: Space.sm) {
      TextField(
        text: $draftMessage,
        prompt: Text(verbatim: "Encrypted message…")
      ) {
        Text(verbatim: "Message")
      }
      .appFont(AppTextRole.body)
      .padding(.horizontal, Space.md)
      .padding(.vertical, Space.sm)
      .catbirdCard(.panel, radius: .lg)

      Button {
        draftMessage = ""
      } label: {
        Text(verbatim: "Send")
      }
      .buttonStyle(.catbird(.primary, size: .md))
    }
    .padding(Space.md)
  }

  private func incomingBubble(sender: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text(verbatim: sender)
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
      Text(verbatim: text)
        .appFont(AppTextRole.body)
        .padding(Space.md)
        .catbirdCard(.panel, radius: .lg)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func outgoingBubble(text: String) -> some View {
    Text(verbatim: text)
      .appFont(AppTextRole.body)
      .padding(Space.md)
      .catbirdCard(.notice(.info), radius: .lg)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

// MARK: - Composer Surface

struct CatalogComposerSurface: View {
  let session: CatbirdCatalogSession
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    #if os(iOS)
    PostComposerViewUIKit(
      quotedPost: PreviewFixtures.post(.textShort),
      initialText: "Checking Catbird design consistency across Light, Dim, True Black, and AX3 #catbird",
      appState: session.appState,
      editingSession: session.sceneContext.composerEditingSession
    )
    .accessibilityIdentifier("catalog.surface.content.composer")
    #else
    NavigationStack {
      VStack(alignment: .leading, spacing: Space.lg) {
        Text(verbatim: "Composer")
          .appFont(AppTextRole.title2)
        if let quoted = PreviewFixtures.post(.textShort) {
          CompactPostCard(
            avatarURL: quoted.author.finalAvatarURL(),
            displayName: quoted.author.displayName ?? quoted.author.handle.description,
            handle: quoted.author.handle.description,
            text: "Quoted fixture post in composer preview."
          )
        }
        Spacer()
      }
      .padding(Space.screenMargin)
      .background(Color.dynamicBackground(session.appState.themeManager, currentScheme: colorScheme))
    }
    .accessibilityIdentifier("catalog.surface.content.composer")
    #endif
  }
}

// MARK: - Ask Catbird Surface

struct CatalogAskCatbirdSurface: View {
  @State private var prompt = ""
  @State private var selectedImageID: String? = CatalogAskCatbirdData.candidates.first?.id
  @State private var showNotice = true

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        AskCatbirdTranscript(
          context: CatalogAskCatbirdData.context,
          turns: CatalogAskCatbirdData.turns,
          streamingTurnID: nil,
          unavailableMessage: nil,
          onRetry: {},
          onSuggestion: { suggestion in prompt = suggestion },
          onSource: { _ in },
          proposalContent: { turn in
            if turn.proposal != nil {
              AskCatbirdProposalCard(
                confirmation: "Open a reply draft for this post? You can edit it before posting.",
                isDedicatedFlow: true,
                isDisabled: false,
                onConfirm: {},
                onCancel: {}
              )
            }
          }
        )

        if showNotice {
          AskCatbirdNotice(
            text: "Earlier context was summarized to stay within on-device model limits.",
            icon: "info.circle",
            color: .secondary,
            onDismiss: { showNotice = false }
          )
        }

        AskCatbirdComposer(
          text: $prompt,
          selectedImageID: $selectedImageID,
          candidates: CatalogAskCatbirdData.candidates,
          imageUnavailableReason: nil,
          isResponding: false,
          isDisabled: false,
          hasUnresolvedProposal: true,
          onSend: {},
          onStop: {}
        )
      }
      .navigationTitle(Text(verbatim: "Ask Catbird"))
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
          } label: {
            Text(verbatim: "Done")
          }
        }
      }
    }
    .accessibilityIdentifier("catalog.surface.content.ask-catbird")
  }
}

private enum CatalogAskCatbirdData {
  static let postURI = "at://did:plc:catalogfixture/app.bsky.feed.post/garden"
  static let fixedDate = Date(timeIntervalSince1970: 1_769_000_000)

  static let context: CopilotContext = {
    let post = CopilotPostEvidence.Post(
      uri: postURI,
      cid: "catalog-fixture-cid",
      authorDID: "did:plc:catalogfixture",
      authorHandle: "maya.example",
      authorName: "Maya Chen",
      text: "The community garden is finally in bloom. We planted native flowers last spring, and bees are returning.",
      media: [.init(kind: .image, altText: "Purple coneflowers beside a sunny garden path.")]
    )
    return .post(
      uri: postURI,
      cid: "catalog-fixture-cid",
      authorDID: "did:plc:catalogfixture",
      text: post.text ?? "",
      evidence: CopilotPostEvidence(selectedPost: post, quotedPosts: [], coverage: [])
    )
  }()

  static let candidates = [
    CopilotImageCandidate(
      id: "catalog-image-1",
      label: "Image 1",
      thumbnailURL: nil,
      altText: "Purple coneflowers beside a sunny garden path."
    )
  ]

  static let turns: [CopilotStoredTurn] = [
    CopilotStoredTurn(
      id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
      role: .user,
      text: "Summarize this post and draft a brief reply.",
      createdAt: fixedDate
    ),
    CopilotStoredTurn(
      id: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
      role: .assistant,
      text: "Maya is sharing the first bloom of native wildflowers in her community garden and noting the return of pollinators.",
      createdAt: fixedDate,
      proposal: .prepareReply(
        uri: postURI,
        cid: "catalog-fixture-cid",
        text: "Love seeing native plants bring pollinators back!"
      ),
      sources: [CopilotSource(label: "Maya Chen · Community garden in bloom", uri: postURI)]
    )
  ]
}
#endif
