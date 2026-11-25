import Petrel
import SwiftUI

// MARK: - Request Model

/// A person shown in a message request: the sender, or another member of the
/// chat. Built from Bluesky chat profiles or MLS enricher data so both request
/// providers render through one row.
struct RequestParticipant: Hashable, Sendable, Identifiable {
  let did: String
  let handle: String?
  let displayName: String?
  let avatarURL: URL?
  var badge: VerificationBadgeKind?
  /// Deleted Bluesky accounts keep a placeholder handle and have no profile.
  var isDeletedAccount = false

  var id: String { did }

  /// The best human-readable name, or nil when only the DID is known.
  var name: String? {
    if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !displayName.isEmpty {
      return displayName
    }
    if isDeletedAccount {
      return String(localized: "Deleted Account", comment: "Placeholder display name for a deleted Bluesky account")
    }
    return handleText
  }

  var handleText: String? {
    guard let handle, !handle.isEmpty, !isDeletedAccount else { return nil }
    return "@\(handle)"
  }

  /// The handle as a secondary line, omitted when it is already the name.
  var secondaryHandle: String? {
    guard let handleText, name != handleText else { return nil }
    return handleText
  }

  var canOpenProfile: Bool { !isDeletedAccount }
}

/// Which request system a request belongs to. Each becomes one list section.
enum MessageRequestSource: String, CaseIterable, Hashable, Sendable {
  case bluesky
  case encrypted

  var title: String {
    switch self {
    case .bluesky:
      String(localized: "Bluesky", comment: "Section header for Bluesky direct message requests")
    case .encrypted:
      String(localized: "Encrypted chats", comment: "Section header for end-to-end encrypted chat requests")
    }
  }
}

/// Where a request came from, which decides how its actions are performed.
enum MessageRequestOrigin: Hashable, Sendable {
  /// A `chat.bsky` conversation with status "request".
  case bluesky(convoID: String)
  /// A verified MLS direct request with a Rust-side consent projection.
  case encryptedDirect(conversationID: String)
  /// A pre-verification MLS request (direct or group) tracked only locally.
  case encryptedLegacy(conversationID: String)

  var source: MessageRequestSource {
    switch self {
    case .bluesky: .bluesky
    case .encryptedDirect, .encryptedLegacy: .encrypted
    }
  }
}

/// The request body shown under the sender: real message text, or a
/// description when the content itself is not shown.
enum MessageRequestPreview: Hashable, Sendable {
  case message(String)
  case description(String)

  var text: String {
    switch self {
    case .message(let text), .description(let text): text
    }
  }
}

/// One pending request, provider-neutral. Rows, the detail screen, and the
/// UI fixture all render from this value.
struct MessageRequestItem: Identifiable, Hashable, Sendable {
  let id: String
  let origin: MessageRequestOrigin
  /// The person who sent the request or invitation, when known.
  let sender: RequestParticipant?
  /// Everyone in the chat except the current user.
  let participants: [RequestParticipant]
  /// Set for group chats: the group's display title.
  let groupTitle: String?
  let memberCount: Int?
  let date: Date?
  let context: String?
  let preview: MessageRequestPreview
  let isUnread: Bool

  var source: MessageRequestSource { origin.source }
  var isGroup: Bool { groupTitle != nil }

  /// Title for the row: the sender's name, else the group, else a description.
  var title: String {
    if let name = sender?.name { return name }
    if let groupTitle { return groupTitle }
    return source == .encrypted
      ? String(localized: "Encrypted chat request", comment: "Fallback title for an anonymous encrypted chat request")
      : String(localized: "Chat request", comment: "Fallback title for an anonymous Bluesky chat request")
  }

  /// Block and report both target the sender's account.
  var canModerateSender: Bool {
    guard let sender else { return false }
    return sender.canOpenProfile
  }
}

/// One provider's requests, shown as one list section.
struct MessageRequestSection: Identifiable, Hashable {
  let source: MessageRequestSource
  let items: [MessageRequestItem]

  var id: MessageRequestSource { source }
}

/// A decision the user can make on a request.
enum MessageRequestDecision: Hashable, Sendable {
  case accept
  case decline
  case block
}

// MARK: - Presentation Logic

/// Pure text and grouping rules for message requests, kept free of SwiftUI so
/// they are unit-testable.
enum MessageRequestPresentation {
  static let newAccountWindow: TimeInterval = 7 * 24 * 60 * 60
  static var encryptedDirectDescription: String {
    String(
      localized: "Wants to start an encrypted chat",
      comment: "Fallback preview description for an incoming encrypted chat request without opening text"
    )
  }

  /// The social-proof line under a sender's name, or nil when nothing is known.
  static func contextLine(
    followsYou: Bool,
    knownFollowerNames: [String],
    knownFollowerCount: Int,
    accountCreatedAt: Date?,
    now: Date
  ) -> String? {
    let names = knownFollowerNames
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    if let first = names.first {
      let total = max(knownFollowerCount, names.count)
      let followedBy: String
      switch total {
      case 1:
        followedBy = String(
          localized: "Followed by \(first)",
          comment: "Social proof showing one mutual follower (%@ = follower name)"
        )
      case 2 where names.count >= 2:
        followedBy = String(
          localized: "Followed by \(first) and \(names[1])",
          comment: "Social proof showing two mutual followers (%1$@ = first follower, %2$@ = second follower)"
        )
      default:
        let others = total - 1
        followedBy = String(
          localized: "Followed by \(first) and \(others) others you know",
          comment: "Social proof showing a named mutual follower and count of additional mutual followers (%1$@ = first follower, %2$lld = additional follower count)"
        )
      }
      return followsYou
        ? String(
            localized: "Follows you · \(followedBy)",
            comment: "Combined social proof when the sender follows you and has mutual followers (%@ = followed-by summary)"
          )
        : followedBy
    }
    if followsYou {
      return String(
        localized: "Follows you",
        comment: "Social proof badge when the request sender follows the current user"
      )
    }
    if let accountCreatedAt {
      let age = now.timeIntervalSince(accountCreatedAt)
      if age >= 0 && age < newAccountWindow {
        return String(
          localized: "New account",
          comment: "Social context badge when the request sender's account is less than 7 days old"
        )
      }
    }
    return nil
  }

  /// Describes a group invitation: `Invited you to "Title" · 4 members`.
  static func groupInvitationDescription(title: String?, memberCount: Int?) -> String {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let memberCount, memberCount > 0 {
      if trimmed.isEmpty {
        return String(
          localized: "Invited you to a group chat · \(memberCount) members",
          comment: "Preview description for an unnamed group chat invitation with member count (%lld = member count)"
        )
      }
      return String(
        localized: "Invited you to “\(trimmed)” · \(memberCount) members",
        comment: "Preview description for a named group chat invitation with member count (%1$@ = group title, %2$lld = member count)"
      )
    }
    if trimmed.isEmpty {
      return String(
        localized: "Invited you to a group chat",
        comment: "Preview description for an unnamed group chat invitation"
      )
    }
    return String(
      localized: "Invited you to “\(trimmed)”",
      comment: "Preview description for a named group chat invitation (%@ = group title)"
    )
  }

  /// Compact trailing timestamp: "now", "5m", "3h", "2d", then a short date.
  static func relativeTimestamp(for date: Date, now: Date, calendar: Calendar = .current) -> String {
    let elapsed = now.timeIntervalSince(date)
    if elapsed < 60 {
      return String(localized: "now", comment: "Compact relative timestamp for less than one minute ago")
    }
    if elapsed < 60 * 60 {
      let minutes = Int(elapsed / 60)
      return String(localized: "\(minutes)m", comment: "Compact relative timestamp in minutes (%lld = minutes)")
    }
    if elapsed < 24 * 60 * 60 {
      let hours = Int(elapsed / (60 * 60))
      return String(localized: "\(hours)h", comment: "Compact relative timestamp in hours (%lld = hours)")
    }
    if elapsed < 7 * 24 * 60 * 60 {
      let days = Int(elapsed / (24 * 60 * 60))
      return String(localized: "\(days)d", comment: "Compact relative timestamp in days (%lld = days)")
    }
    let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return date.formatted(style)
    }
    return date.formatted(style.year())
  }

  /// Non-empty sections in display order. Empty sections are hidden.
  static func sections(
    bluesky: [MessageRequestItem],
    encrypted: [MessageRequestItem]
  ) -> [MessageRequestSection] {
    [
      MessageRequestSection(source: .bluesky, items: bluesky),
      MessageRequestSection(source: .encrypted, items: encrypted),
    ].filter { !$0.items.isEmpty }
  }

  /// Parses the RFC 3339 timestamps carried in MLS request metadata.
  static func parseTimestamp(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
  }
}

// MARK: - Bluesky Mapping

extension RequestParticipant {
  init(bluesky profile: ChatBskyActorDefs.ProfileViewBasic) {
    self.init(
      did: profile.did.didString(),
      handle: profile.handle.description,
      displayName: profile.displayName,
      avatarURL: profile.finalAvatarURL(),
      badge: VerificationBadge.kind(for: profile.verification, did: profile.did),
      isDeletedAccount: profile.isDeletedBlueskyChatAccount
    )
  }
}

extension MessageRequestItem {
  init(bluesky convo: ChatBskyConvoDefs.ConvoView, currentUserDID: String, now: Date) {
    let others = convo.displayMembersExcludingCurrentUser(currentUserDID: currentUserDID)
    let senderProfile = Self.blueskySender(of: convo, currentUserDID: currentUserDID)
    let isGroup = convo.isGroupConversation
    let viewer = senderProfile?.viewer
    self.init(
      id: "bsky:\(convo.id)",
      origin: .bluesky(convoID: convo.id),
      sender: senderProfile.map(RequestParticipant.init(bluesky:)),
      participants: others.map(RequestParticipant.init(bluesky:)),
      groupTitle: isGroup ? convo.displayTitle(currentUserDID: currentUserDID) : nil,
      memberCount: isGroup ? (convo.groupMetadata?.memberCount ?? convo.members.count) : nil,
      date: Self.blueskyDate(convo.lastMessage),
      context: MessageRequestPresentation.contextLine(
        followsYou: viewer?.followedBy != nil,
        knownFollowerNames: viewer?.knownFollowers?.followers.map { profile in
          profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "@\(profile.handle.description)"
        } ?? [],
        knownFollowerCount: viewer?.knownFollowers?.count ?? 0,
        accountCreatedAt: senderProfile?.createdAt?.date,
        now: now
      ),
      preview: Self.blueskyPreview(convo, isGroup: isGroup),
      isUnread: convo.unreadCount > 0
    )
  }

  /// The member who wrote the latest message, else the group owner, else the
  /// first other member.
  private static func blueskySender(
    of convo: ChatBskyConvoDefs.ConvoView,
    currentUserDID: String
  ) -> ChatBskyActorDefs.ProfileViewBasic? {
    if case .chatBskyConvoDefsMessageView(let message) = convo.lastMessage {
      let senderDID = message.sender.did.didString()
      if senderDID != currentUserDID,
         let member = convo.members.first(where: { $0.did.didString() == senderDID }) {
        return member
      }
    }
    return convo.primaryMember(currentUserDID: currentUserDID)
  }

  private static func blueskyDate(_ message: ChatBskyConvoDefs.ConvoViewLastMessageUnion?) -> Date? {
    switch message {
    case .chatBskyConvoDefsMessageView(let view): view.sentAt.date
    case .chatBskyConvoDefsSystemMessageView(let view): view.sentAt.date
    case .chatBskyConvoDefsDeletedMessageView, .unexpected, nil: nil
    }
  }

  private static func blueskyPreview(_ convo: ChatBskyConvoDefs.ConvoView, isGroup: Bool) -> MessageRequestPreview {
    switch convo.lastMessage {
    case .chatBskyConvoDefsMessageView(let view):
      let text = view.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty
        ? .description(String(localized: "Sent an attachment", comment: "Message request preview when the message has no text"))
        : .message(text)
    case .chatBskyConvoDefsDeletedMessageView:
      return .description(String(localized: "Message deleted", comment: "Message request preview when the latest message was deleted"))
    case .chatBskyConvoDefsSystemMessageView, .unexpected, nil:
      if isGroup {
        return .description(MessageRequestPresentation.groupInvitationDescription(
          title: convo.groupMetadata?.name, memberCount: convo.groupMetadata?.memberCount ?? convo.members.count))
      }
      return .description(String(localized: "Wants to chat", comment: "Message request preview when no message has been sent yet"))
    }
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Request Row

/// One request in the Message Requests list. The sender block opens their
/// profile, the message block opens the request detail, and the button pair
/// makes the decision. Block and Report live in the "…" menu, swipe actions,
/// and context menu.
struct RequestRow: View {
  let item: MessageRequestItem
  let inFlight: MessageRequestDecision?
  let onOpenProfile: (String) -> Void
  let onOpenDetail: () -> Void
  let onAccept: () -> Void
  let onDecline: () -> Void
  let onBlock: () -> Void
  let onReport: () -> Void

  private var isProcessing: Bool { inFlight != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.base) {
      HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
        senderButton
        Spacer(minLength: DesignTokens.Spacing.xs)
        trailingAccessories
      }

      Button(action: onOpenDetail) {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
          if let context = item.context {
            Label(context, systemImage: "person.2")
              .labelStyle(RequestContextLabelStyle())
          }
          previewText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(detailAccessibilityLabel)
      .accessibilityHint("Opens the full request")
      .accessibilityIdentifier("messageRequests.detail.\(item.id)")

      RequestDecisionButtons(
        inFlight: inFlight,
        placement: .inline,
        onAccept: onAccept,
        onDecline: onDecline
      )
    }
    .padding(.vertical, DesignTokens.Spacing.sm)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("messageRequests.row.\(item.id)")
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      if item.canModerateSender {
        Button(action: onBlock) {
          Label("Block", systemImage: "hand.raised")
        }
        .tint(.red)
        Button(action: onReport) {
          Label("Report", systemImage: "exclamationmark.bubble")
        }
        .tint(.orange)
      }
    }
    .contextMenu {
      Button(action: onOpenDetail) {
        Label("View Request", systemImage: "text.bubble")
      }
      if let sender = item.sender, sender.canOpenProfile {
        Button { onOpenProfile(sender.did) } label: {
          Label("View Profile", systemImage: "person.crop.circle")
        }
      }
      moderationMenuItems
    }
  }

  // MARK: - Sender

  @ViewBuilder
  private var senderButton: some View {
    if let sender = item.sender, sender.canOpenProfile {
      Button { onOpenProfile(sender.did) } label: { senderLabel }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title), view profile")
        .accessibilityIdentifier("messageRequests.profile.\(item.id)")
    } else {
      senderLabel
    }
  }

  private var senderLabel: some View {
    HStack(alignment: .center, spacing: DesignTokens.Spacing.base) {
      RequestAvatar(item: item, size: DesignTokens.Size.avatarLG)

      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Text(item.title)
            .designCallout()
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .lineLimit(1)
          if let badge = item.sender?.badge {
            VerificationBadgeView(kind: badge)
              .appFont(AppTextRole.caption)
          }
          if item.isUnread {
            Circle()
              .fill(Color.accentColor)
              .frame(width: 8, height: 8)
              .accessibilityLabel("Unread")
          }
        }
        if let handle = item.sender?.secondaryHandle {
          Text(verbatim: handle)
            .designFootnote()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
    .contentShape(Rectangle())
  }

  // MARK: - Trailing

  private var trailingAccessories: some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      if let date = item.date {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          Text(MessageRequestPresentation.relativeTimestamp(for: date, now: context.date))
            .designCaption()
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
        }
        .accessibilityLabel(date.formatted(.relative(presentation: .named)))
      }

      Menu {
        Button(action: onOpenDetail) {
          Label("View Request", systemImage: "text.bubble")
        }
        moderationMenuItems
      } label: {
        Image(systemName: "ellipsis")
          .appFont(AppTextRole.body).fontWeight(.semibold)
          .foregroundStyle(.secondary)
          .frame(width: 32, height: 32)
          .contentShape(Rectangle())
      }
      .menuIndicator(.hidden)
      .buttonStyle(.plain)
      .disabled(isProcessing)
      .accessibilityLabel("More actions")
      .accessibilityIdentifier("messageRequests.more.\(item.id)")
    }
  }

  @ViewBuilder
  private var moderationMenuItems: some View {
    if item.canModerateSender {
      Divider()
      Button(action: onReport) {
        Label("Report…", systemImage: "exclamationmark.bubble")
      }
      Button(role: .destructive, action: onBlock) {
        Label("Block…", systemImage: "hand.raised")
      }
    }
  }

  // MARK: - Preview

  @ViewBuilder
  private var previewText: some View {
    switch item.preview {
    case .message(let text):
      Text(verbatim: text)
        .designFootnote()
        .foregroundStyle(.primary)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
    case .description(let text):
      Text(text)
        .designFootnote()
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
    }
  }

  private var detailAccessibilityLabel: String {
    [item.context, item.preview.text].compactMap { $0 }.joined(separator: ". ")
  }
}

/// Small secondary context line ("Follows you") with a leading glyph.
private struct RequestContextLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: DesignTokens.Spacing.xs) {
      configuration.icon
        .appFont(AppTextRole.caption2)
        .accessibilityHidden(true)
      configuration.title
        .designCaption()
        .lineLimit(1)
    }
    .foregroundStyle(.secondary)
  }
}

// MARK: - Avatar

/// Sender avatar, or a stacked group avatar when the sender is unknown.
struct RequestAvatar: View {
  let item: MessageRequestItem
  let size: CGFloat

  var body: some View {
    if let sender = item.sender {
      AsyncProfileImage(url: sender.avatarURL, size: size)
        .overlay(alignment: .bottomTrailing) { encryptedBadge }
        .accessibilityHidden(true)
    } else if !item.participants.isEmpty {
      MLSGroupAvatarView(
        participants: item.participants.map {
          MLSParticipantViewModel(id: $0.did, handle: $0.handle ?? "", displayName: $0.displayName, avatarURL: $0.avatarURL)
        },
        size: size
      )
      .overlay(alignment: .bottomTrailing) { encryptedBadge }
      .accessibilityHidden(true)
    } else {
      Image(systemName: item.isGroup ? "person.2.fill" : "lock.fill")
        .font(.system(size: size * 0.4))
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
        .background(.quaternary, in: Circle())
        .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private var encryptedBadge: some View {
    if item.source == .encrypted {
      Image(systemName: "lock.fill")
        .font(.system(size: size * 0.2, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: size * 0.38, height: size * 0.38)
        .background(Color.accentColor, in: Circle())
        .overlay(Circle().stroke(Color.systemBackground, lineWidth: 2))
        .offset(x: 2, y: 2)
    }
  }
}

// MARK: - Decision Buttons

/// Where the Decline/Accept pair is drawn. Inline pairs sit in list rows;
/// floating pairs sit in a bottom bar over scrolling content.
enum RequestDecisionPlacement {
  case inline
  case floating
}

/// Full-width Decline + Accept pair with at least 44pt touch targets. The
/// button for the in-flight decision shows a spinner; both disable meanwhile.
struct RequestDecisionButtons: View {
  let inFlight: MessageRequestDecision?
  let placement: RequestDecisionPlacement
  var canAccept = true
  var canDecline = true
  let onAccept: () -> Void
  let onDecline: () -> Void

  private var buttonSize: CatbirdButtonSize { placement == .floating ? .lg : .md }

  var body: some View {
    HStack(spacing: Space.md) {
      Button(action: onDecline) {
        buttonLabel(
          "Decline",
          progressLabel: "Declining",
          showsProgress: inFlight == .decline
        )
      }
      .modifier(
        RequestDecisionButtonStyle(
          isAccept: false, placement: placement, size: buttonSize,
          isLoading: inFlight == .decline)
      )
      .disabled(inFlight != nil || !canDecline)

      Button(action: onAccept) {
        buttonLabel(
          "Accept",
          progressLabel: "Accepting",
          showsProgress: inFlight == .accept
        )
      }
      .modifier(
        RequestDecisionButtonStyle(
          isAccept: true, placement: placement, size: buttonSize,
          isLoading: inFlight == .accept)
      )
      .disabled(inFlight != nil || !canAccept)
    }
  }

  private func buttonLabel(
    _ title: LocalizedStringKey,
    progressLabel: LocalizedStringKey,
    showsProgress: Bool
  ) -> some View {
    Text(title)
      .opacity(showsProgress && usesGlass ? 0 : 1)
      .overlay {
        if showsProgress && usesGlass {
          ProgressView().controlSize(.small)
        }
      }
      .frame(maxWidth: .infinity)
      .accessibilityLabel(showsProgress ? Text(progressLabel) : Text(title))
  }

  /// Floating pair on iOS 26 / macOS 26 keeps the system glass styles, which
  /// need no kit spinner support, so the spinner is drawn by the label.
  private var usesGlass: Bool {
    if #available(iOS 26.0, macOS 26.0, *) { return placement == .floating }
    return false
  }
}

/// Kit button style inline and before iOS 26; system glass buttons when
/// floating over scrolling content on iOS 26 / macOS 26 (the bar background
/// draws no backdrop of its own there).
struct RequestDecisionButtonStyle: ViewModifier {
  let isAccept: Bool
  let placement: RequestDecisionPlacement
  let size: CatbirdButtonSize
  let isLoading: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *), placement == .floating {
      if isAccept {
        content.modifier(RequestAcceptButtonStyle()).controlSize(.large)
      } else {
        content.modifier(RequestDeclineButtonStyle(placement: placement)).controlSize(.large)
      }
    } else {
      content.buttonStyle(
        .catbird(isAccept ? .primary : .tonal, size: size, fullWidth: true, isLoading: isLoading)
      )
    }
  }
}

/// Liquid Glass prominent style on iOS 26 / macOS 26, bordered prominent before.
struct RequestAcceptButtonStyle: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      content.buttonStyle(.glassProminent)
    } else {
      content.buttonStyle(.borderedProminent)
    }
  }
}

/// Bordered inline; glass when floating over content on iOS 26 / macOS 26.
struct RequestDeclineButtonStyle: ViewModifier {
  let placement: RequestDecisionPlacement

  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *), placement == .floating {
      content.buttonStyle(.glass)
    } else {
      content.buttonStyle(.bordered)
    }
  }
}

/// Bottom bar hosting a floating decision pair: Liquid Glass buttons over the
/// content on iOS 26 / macOS 26, a bar material before.
struct RequestDecisionBar<Header: View>: View {
  let inFlight: MessageRequestDecision?
  var canAccept = true
  var canDecline = true
  let onAccept: () -> Void
  let onDecline: () -> Void
  @ViewBuilder var header: () -> Header

  var body: some View {
    VStack(spacing: DesignTokens.Spacing.sm) {
      header()
      RequestDecisionButtons(
        inFlight: inFlight,
        placement: .floating,
        canAccept: canAccept,
        canDecline: canDecline,
        onAccept: onAccept,
        onDecline: onDecline
      )
    }
    .padding(.horizontal, DesignTokens.Spacing.xl)
    .padding(.top, DesignTokens.Spacing.base)
    .padding(.bottom, DesignTokens.Spacing.sm)
    .modifier(RequestDecisionBarBackground())
  }
}

extension RequestDecisionBar where Header == EmptyView {
  init(
    inFlight: MessageRequestDecision?,
    canAccept: Bool = true,
    canDecline: Bool = true,
    onAccept: @escaping () -> Void,
    onDecline: @escaping () -> Void
  ) {
    self.init(
      inFlight: inFlight, canAccept: canAccept, canDecline: canDecline,
      onAccept: onAccept, onDecline: onDecline, header: { EmptyView() })
  }
}

private struct RequestDecisionBarBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      GlassEffectContainer { content }
    } else {
      content.background(.bar)
    }
  }
}
