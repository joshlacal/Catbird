import CatbirdMLSCore
import SwiftUI

/// Literal request presentation shared by iPhone, iPad, macOS and UI fixtures.
/// It has no media, reaction, receipt, or networking dependency.
struct MLSRequestPresentation: View {
  let consent: RequestConsent
  let preview: RequestPreview?
  let busy: Bool
  let canAccept: Bool
  let canClose: Bool
  let error: String?
  let onAccept: () -> Void
  let onDecline: () -> Void
  let onBlock: () -> Void
  let onRefresh: () -> Void
  var onOpenInvitation: ((GroupInvitationReference) -> Void)?

  /// The decision last tapped, so the bar can show progress on that button
  /// while `busy` is true.
  @State private var tapped: MessageRequestDecision?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Label(title, systemImage: "lock.fill").font(.headline)
        switch preview {
        case .ready(let text, let invitation):
          Text(verbatim: text)
            .textSelection(.enabled)
            .accessibilityIdentifier("request-first-message")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.quaternary, in: .rect(cornerRadius: 18))
          if let invitation {
            Text("Includes a group invitation. Accepting this message request does not accept the group invitation.")
              .font(.caption).foregroundStyle(.secondary)
            if let onOpenInvitation {
              Button("View group invitation") { onOpenInvitation(invitation) }
            }
          }
        case .unavailable:
          Text("This introduction is unavailable on this device. Accepting does not recover an expired introduction.")
            .foregroundStyle(.secondary)
        case nil:
          ProgressView("Preparing encrypted preview…")
        }
        if consent == .outgoingPending {
          Text("Waiting for acceptance. You can send more messages after your request is accepted.").foregroundStyle(.secondary)
        } else if consent == .accepted {
          ProgressView("Request accepted. Setting up secure access on this device…")
        }
        if let error { Text(error).foregroundStyle(.red) }
        HStack(spacing: 16) {
          if consent == .incomingPending {
            Button(role: .destructive, action: onBlock) {
              Label("Block", systemImage: "hand.raised")
            }
            .disabled(busy)
          } else if consent == .outgoingPending && canClose {
            Button("Close request", role: .destructive, action: onDecline).disabled(busy)
          }
          Button(action: onRefresh) {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .disabled(busy)
          if busy && consent != .incomingPending { ProgressView() }
        }
        .buttonStyle(.borderless)
        .font(.footnote)
      }
      .padding()
      .frame(maxWidth: 720, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .safeAreaInset(edge: .bottom) {
      if consent == .incomingPending {
        RequestDecisionBar(
          inFlight: busy ? tapped : nil,
          canAccept: canAccept && !busy,
          canDecline: canClose && !busy,
          onAccept: { tapped = .accept; onAccept() },
          onDecline: { tapped = .decline; onDecline() }
        )
      }
    }
  }

  private var title: String {
    switch consent {
    case .incomingPending: "Encrypted message request"
    case .outgoingPending: "Request sent"
    case .accepted: "Request accepted"
    case .closed: "Conversation closed"
    }
  }
}

#if DEBUG
/// Presentation-only test state. It deliberately makes no cryptographic claim.
struct MLSEncryptedRequestUIFixture: View {
  @State private var accepted = false
  @State private var composer = ""
  @State private var openedGroup = false
  private var outgoing: Bool { ProcessInfo.processInfo.arguments.contains("--request-outgoing") }

  private var invitation: GroupInvitationReference? {
    guard ProcessInfo.processInfo.arguments.contains("--request-invitation") else { return nil }
    return GroupInvitationReference(authorityDid: "did:web:chat.catbird.blue",
      conversationId: "00000000-0000-4000-8000-000000000011", invitationTransitionId: "00000000-0000-4000-8000-000000000012",
      invitedByDid: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", invitedByDeviceId: "00000000-0000-4000-8000-000000000013",
      recipientDid: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb")
  }

  var body: some View {
    NavigationStack {
      if openedGroup {
        Text("Group invitation remains pending").accessibilityIdentifier("fixture-group-pending")
      } else if accepted {
        VStack(alignment: .leading, spacing: 20) {
          Text("Hello, Bob").accessibilityIdentifier("request-first-message")
          TextEditor(text: $composer).accessibilityLabel("Message composer")
          if invitation != nil { Button("View group invitation") { openedGroup = true } }
        }.padding().navigationTitle("Conversation")
      } else {
        MLSRequestPresentation(consent: outgoing ? .outgoingPending : .incomingPending,
          preview: .ready(text: "Hello, Bob", invitation: invitation), busy: false,
          canAccept: !outgoing, canClose: true, error: nil,
          onAccept: { accepted = true }, onDecline: {}, onBlock: {}, onRefresh: {},
          onOpenInvitation: { _ in openedGroup = true })
          .navigationTitle("Message Request")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
  }
}
#endif
