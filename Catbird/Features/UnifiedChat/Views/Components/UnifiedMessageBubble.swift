import SwiftUI
import NukeUI

enum UnifiedMessageGroupPosition: Sendable {
  case single
  case first
  case middle
  case last

  var isFirstInGroup: Bool { self == .single || self == .first }
  var isLastInGroup: Bool { self == .single || self == .last }

  /// For incoming messages, we show the avatar at the end of a grouped run (iMessage-style).
  var showsAvatar: Bool { isLastInGroup }
}

enum UnifiedMessageGrouping {
  private static let defaultMaxGap: TimeInterval = 5 * 60

  static func groupPosition<Message: UnifiedChatMessage>(
    for messageID: String,
    in messages: [Message],
    maxGap: TimeInterval = defaultMaxGap
  ) -> UnifiedMessageGroupPosition {
    guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return .single }
    return groupPosition(for: index, in: messages, maxGap: maxGap)
  }

  static func groupPosition<Message: UnifiedChatMessage>(
    for index: Int,
    in messages: [Message],
    maxGap: TimeInterval = defaultMaxGap
  ) -> UnifiedMessageGroupPosition {
    guard messages.indices.contains(index) else { return .single }

    let current = messages[index]

    let prevIsGrouped: Bool = {
      guard index > messages.startIndex else { return false }
      return canGroup(messages[index - 1], current, maxGap: maxGap)
    }()

    let nextIsGrouped: Bool = {
      let nextIndex = index + 1
      guard messages.indices.contains(nextIndex) else { return false }
      return canGroup(current, messages[nextIndex], maxGap: maxGap)
    }()

    switch (prevIsGrouped, nextIsGrouped) {
    case (false, false): return .single
    case (false, true): return .first
    case (true, true): return .middle
    case (true, false): return .last
    }
  }

  private static func canGroup<Message: UnifiedChatMessage>(
    _ earlier: Message,
    _ later: Message,
    maxGap: TimeInterval
  ) -> Bool {
    guard earlier.senderID == later.senderID else { return false }
    guard earlier.isFromCurrentUser == later.isFromCurrentUser else { return false }

    let gap = abs(later.sentAt.timeIntervalSince(earlier.sentAt))
    return gap <= maxGap
  }
}

/// Unified message bubble component with Liquid Glass support for iOS 26+
struct UnifiedMessageBubble<Message: UnifiedChatMessage>: View {
  let message: Message
  @Binding var navigationPath: NavigationPath
  var onReactionTapped: ((String) -> Void)?
  var onAddReaction: ((String) -> Void)?
  var onRequestEmojiPicker: ((String) -> Void)? = nil
  var onLongPress: ((CGRect) -> Void)?
  var onReactionLongPress: (() -> Void)? = nil
  var showSenderInfo: Bool = true
  var groupPosition: UnifiedMessageGroupPosition = .single

  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme

  @State private var bubbleGlobalFrame: CGRect = .zero
  @State private var showingMLSErrorDetails = false

  private let cornerRadius: CGFloat = 18
  private let maxBubbleWidth: CGFloat = 280

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      if message.isFromCurrentUser {
        Spacer(minLength: 50)
        messageContent
      } else {
        if showSenderInfo {
          if groupPosition.showsAvatar {
            avatarView
          } else {
            avatarPlaceholderSpacer
          }
        }
        messageContent
        Spacer(minLength: 50)
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, groupPosition.isFirstInGroup ? 4 : 1)
    .padding(.bottom, groupPosition.isLastInGroup ? 4 : 1)
  }

  // MARK: - Avatar

  @ViewBuilder
  private var avatarView: some View {
    if let avatarURL = message.senderAvatarURL {
      LazyImage(url: avatarURL) { state in
        if let image = state.image {
          image
            .resizable()
            .scaledToFill()
        } else {
          placeholderAvatar
        }
      }
      .frame(width: 32, height: 32)
      .clipShape(Circle())
    } else {
      placeholderAvatar
    }
  }

  private var placeholderAvatar: some View {
    Circle()
      .fill(Color.gray.opacity(0.3))
      .frame(width: 32, height: 32)
      .overlay {
        Text(message.senderDisplayName?.prefix(1).uppercased() ?? "?")
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(.secondary)
      }
  }

  private var avatarPlaceholderSpacer: some View {
    Color.clear
      .frame(width: 32, height: 32)
  }

  // MARK: - Message Content

  @ViewBuilder
  private var messageContent: some View {
    VStack(alignment: message.isFromCurrentUser ? .trailing : .leading, spacing: 4) {
      // Sender name for group chats
      if showSenderInfo, groupPosition.isFirstInGroup, !message.isFromCurrentUser, let name = message.senderDisplayName {
        Text(name)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, 4)
      }

      bubbleContent
        .bubbleBackground(
          isCurrentUser: message.isFromCurrentUser,
          cornerRadius: cornerRadius,
          colorScheme: colorScheme
        )
        .background(
          GeometryReader { proxy in
            Color.clear
              .preference(key: BubbleFramePreferenceKey.self, value: proxy.frame(in: .global))
          }
        )
        .onPreferenceChange(BubbleFramePreferenceKey.self) { bubbleGlobalFrame = $0 }
        .onLongPressGesture {
          onLongPress?(bubbleGlobalFrame)
        }

      // Reactions
      if !message.reactions.isEmpty {
        UnifiedMessageReactions(
          reactions: message.reactions,
          isCurrentUser: message.isFromCurrentUser,
          onReactionTapped: { emoji in
            onReactionTapped?(emoji)
          },
          onReactionLongPress: { _ in
            onReactionLongPress?()
          }
        )
      }

      // Timestamp and status
      if groupPosition.isLastInGroup {
        HStack(spacing: 4) {
          Text(message.sentAt, style: .time)
            .font(.caption2)
            .foregroundStyle(.secondary)

          sendStateIndicator
        }
      }
    }
  }

  @ViewBuilder
  private var bubbleContent: some View {
    let mlsDebugInfo = (message as? MLSMessageAdapter)?.debugInfo

    BubbleWidthLimiter(maxWidth: maxBubbleWidth) {
      VStack(alignment: .leading, spacing: 8) {
        if mlsDebugInfo != nil {
          HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
            Text("Message unavailable")
              .font(.caption)
              .foregroundStyle(message.isFromCurrentUser ? .white.opacity(0.85) : .secondary)
            Spacer(minLength: 0)
            Image(systemName: "info.circle")
              .font(.caption)
              .foregroundStyle(message.isFromCurrentUser ? .white.opacity(0.85) : .secondary)
          }
          .accessibilityHint("Tap for error details")
        }

        // Embed preview
        if let embed = message.embed {
          UnifiedEmbedView(embed: embed, navigationPath: $navigationPath)
            .frame(maxWidth: maxBubbleWidth)
        }

        // Message text
        if !message.text.isEmpty {
          Text(message.text)
            .font(.body)
            .foregroundStyle(message.isFromCurrentUser ? .white : .primary)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      if mlsDebugInfo != nil {
        showingMLSErrorDetails = true
      }
    }
    .sheet(isPresented: $showingMLSErrorDetails) {
      if let info = mlsDebugInfo {
        MLSMessageErrorDetailsSheet(info: info)
      }
    }
  }

  // MARK: - MLS Error Details

  private struct MLSMessageErrorDetailsSheet: View {
    let info: MLSMessageAdapter.MLSMessageDebugInfo

    var body: some View {
      NavigationStack {
        List {
          Section("Error") {
            if let processingError = info.processingError {
              DetailRow(label: "Processing Error", value: processingError)
            }
            if let validation = info.validationFailureReason {
              DetailRow(label: "Validation Failure", value: validation)
            }
            if let attempts = info.processingAttempts {
              DetailRow(label: "Processing Attempts", value: "\(attempts)")
            }
          }

          Section("Debug") {
            DetailRow(label: "Message ID", value: info.messageID)
            DetailRow(label: "Conversation ID", value: info.conversationID)
            DetailRow(label: "Sender DID", value: info.senderDID)
            if let epoch = info.epoch {
              DetailRow(label: "Epoch", value: "\(epoch)")
            }
            if let sequence = info.sequence {
              DetailRow(label: "Sequence", value: "\(sequence)")
            }
            DetailRow(label: "Sent At", value: info.sentAt.formatted(date: .abbreviated, time: .standard))
          }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Message Error")
        .navigationBarTitleDisplayMode(.inline)
      }
    }

    private struct DetailRow: View {
      let label: String
      let value: String

      var body: some View {
        VStack(alignment: .leading, spacing: 4) {
          Text(label)
            .font(.footnote)
            .foregroundStyle(.secondary)
          Text(value)
            .font(.body)
            .textSelection(.enabled)
        }
        .padding(.vertical, 2)
      }
    }
  }

  // MARK: - Send State Indicator

  @ViewBuilder
  private var sendStateIndicator: some View {
    switch message.sendState {
    case .sending:
      Image(systemName: "clock")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .symbolEffect(.pulse)
    case .sent:
      Image(systemName: "checkmark")
        .font(.caption2)
        .foregroundStyle(.secondary)
    case .delivered:
      Image(systemName: "checkmark")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .overlay {
          Image(systemName: "checkmark")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .offset(x: 4)
        }
    case .read:
      Image(systemName: "checkmark")
        .font(.caption2)
        .foregroundStyle(Color.accentColor)
        .overlay {
          Image(systemName: "checkmark")
            .font(.caption2)
            .foregroundStyle(Color.accentColor)
            .offset(x: 4)
        }
    case .failed:
      Image(systemName: "exclamationmark.circle.fill")
        .font(.caption2)
        .foregroundStyle(.red)
    }
  }
}

// MARK: - Layout Helpers

private struct BubbleWidthLimiter: Layout {
  let maxWidth: CGFloat

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    guard let subview = subviews.first else { return .zero }

    let effectiveMaxWidth = min(maxWidth, proposal.width ?? maxWidth)
    guard effectiveMaxWidth.isFinite, effectiveMaxWidth > 0 else { return .zero }

    // Measure unconstrained to get a natural (hugging) width.
    let naturalSize = subview.sizeThatFits(.unspecified)
    if
      naturalSize.width.isFinite,
      naturalSize.height.isFinite,
      naturalSize.width <= effectiveMaxWidth
    {
      return CGSize(width: max(naturalSize.width, 0), height: max(naturalSize.height, 0))
    }

    // Re-measure with a max width to wrap multi-line text/embeds.
    let constrainedSize = subview.sizeThatFits(
      ProposedViewSize(width: effectiveMaxWidth, height: nil)
    )
    let width: CGFloat
    if constrainedSize.width.isFinite {
      width = min(max(constrainedSize.width, 0), effectiveMaxWidth)
    } else {
      width = effectiveMaxWidth
    }

    let fallbackHeight = naturalSize.height.isFinite ? max(naturalSize.height, 0) : 0
    let height = constrainedSize.height.isFinite ? max(constrainedSize.height, 0) : fallbackHeight

    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    guard let subview = subviews.first else { return }
    subview.place(
      at: bounds.origin,
      anchor: .topLeading,
      proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
    )
  }
}

// MARK: - iMessage-Style Reaction Bar

private struct BubbleFramePreferenceKey: PreferenceKey {
  static var defaultValue: CGRect = .zero

  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    value = nextValue()
  }
}

/// A horizontal bar of quick reaction emojis that appears on long press
struct UnifiedQuickReactionBar: View {
  static let defaultQuickReactions = ["❤️","👍", "😂", "😲", "😢", "🔥"]

  let quickReactions: [String]
  let onReactionSelected: (String) -> Void
  let onMoreTapped: () -> Void

  var body: some View {
    let content = HStack(spacing: 8) {
      ForEach(quickReactions, id: \.self) { emoji in
        Button {
          onReactionSelected(emoji)
        } label: {
          Text(emoji)
            .font(.title2)
        }
        .buttonStyle(ReactionButtonStyle())
      }

      // "More" button for full emoji picker
      Button {
        onMoreTapped()
      } label: {
        Image(systemName: "plus")
          .font(.title3.weight(.medium))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(ReactionButtonStyle())
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)

    if #available(iOS 26.0, macOS 26.0, *) {
      content
        .glassEffect(.regular.interactive())
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
    } else {
      content
        .background(
          Capsule()
            .fill(.ultraThinMaterial)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
    }
  }
}

/// Button style for reaction bar items
private struct ReactionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(width: 36, height: 36)
      .scaleEffect(configuration.isPressed ? 1.3 : 1.0)
      .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
  }
}

// MARK: - iMessage-Style Bubble Background

private extension View {
  @ViewBuilder
  func bubbleBackground(
    isCurrentUser: Bool,
    cornerRadius: CGFloat,
    colorScheme: ColorScheme
  ) -> some View {
    self.background(
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(
          isCurrentUser
            ? Color.accentColor
            : (colorScheme == .dark ? Color(white: 0.22) : Color(white: 0.93))
        )
    )
  }
}

// MARK: - Preview

#Preview {
  struct PreviewMessage: UnifiedChatMessage {
    var id: String = "1"
    var text: String = "Hello, this is a test message!"
    var senderID: String = "user1"
    var senderDisplayName: String? = "John Doe"
    var senderAvatarURL: URL? = nil
    var sentAt: Date = Date()
    var isFromCurrentUser: Bool = false
    var reactions: [UnifiedReaction] = []
    var embed: UnifiedEmbed? = nil
    var sendState: MessageSendState = .sent
  }

  return VStack(spacing: 16) {
    UnifiedMessageBubble(
      message: PreviewMessage(),
      navigationPath: .constant(NavigationPath())
    )
    UnifiedMessageBubble(
      message: PreviewMessage(
        text: "This is my reply!",
        isFromCurrentUser: true
      ),
      navigationPath: .constant(NavigationPath())
    )
  }
  .padding()
}
