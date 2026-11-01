import SwiftUI
#if os(iOS)
import QuartzCore
import UIKit
#endif

// The three ways a moderation decision shows on a post: a hidden row (a list
// filter the surface did not apply), a body gate (`ContentHider` upstream) and
// a media gate. A reveal is keyed by the causes it was given
// (`ModerationRevealState`), so a different set of causes is concealed again
// even when the hosting view is reused for another post. The body and media
// gates also record it for their post (`\.moderationRevealSubject`) in
// `ModerationRevealStore`, so it survives cell reuse and re-appearance.

// MARK: - Hidden row

/// Replaces a post that `contentList` filters on a surface that does not drop
/// rows (profile tabs, likes, bookmarks, thread replies, notifications). The
/// headline names who hides it: the account's adult-content setting, the
/// moderators, or the user's own label setting.
struct ModerationHiddenPostRow: View {
  let presentation: PostModerationPresentation
  let onReveal: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "eye.slash")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(ModerationGateText.hiddenRowHeadline(for: presentation))
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
        Text(ModerationGateText.hiddenRowDetail(for: presentation))
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if presentation.hiddenRowAllowsReveal {
        Button("Show", action: onReveal)
          .appFont(AppTextRole.subheadline)
          .buttonStyle(.borderless)
          .frame(minWidth: 44, minHeight: 44)
          .accessibilityHint("Shows the hidden post")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("moderation.hiddenRow")
  }
}

/// The bar above a hidden row's post once the viewer showed it. It keeps the
/// cause in view and offers Hide, so the reveal is reversible like the body
/// and media gates (upstream `PostHider` keeps its header after override).
struct ModerationRevealedPostBar: View {
  let presentation: PostModerationPresentation
  let onHide: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Image(systemName: "eye")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(ModerationGateText.hiddenRowDetail(for: presentation))
        .appFont(AppTextRole.subheadline)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
      Button("Hide", action: onHide)
        .appFont(AppTextRole.subheadline)
        .buttonStyle(.borderless)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint("Hides the post again")
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .background(Color(platformColor: .platformSystemGray6), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("moderation.revealedRow")
  }
}

// MARK: - Body gate

/// One compact warning bar that conceals its content (post text and embed
/// together) until shown. Nothing inside is built while concealed.
struct ModerationContentGate<Content: View>: View {
  let ui: ModerationUI
  @ViewBuilder let content: () -> Content
  /// Show or Hide chosen in this view. `nil` until the viewer chooses, so the
  /// gate starts from `ModerationRevealStore`; setting it re-renders the gate.
  @State private var localReveal: ModerationRevealState?
  @Environment(AppState.self) private var appState
  @Environment(\.postID) private var postID
  @Environment(\.moderationRevealSubject) private var revealSubject
  @Environment(\.invalidateFeedRowHeight) private var invalidateFeedRowHeight

  /// The post `ModerationRevealStore` records this gate's reveal under.
  private var storeSubject: String { revealSubject.isEmpty ? postID : revealSubject }

  private var revealed: Bool {
    if storeSubject.isEmpty {
      return localReveal?.isRevealed(ui) ?? false
    }
    return ModerationRevealStore.shared.isRevealed(
      ui, gate: .body, subject: storeSubject, accountDID: appState.userDID)
  }

  var body: some View {
    Group {
      if ui.blur {
        VStack(alignment: .leading, spacing: 6) {
          gateBar
          if revealed {
            content()
              .postRevealFade(isEnabled: true)
          }
        }
      } else {
        content()
      }
    }
    .onChange(of: storeSubject) { _, _ in
      localReveal = nil
    }
  }

  private var gateBar: some View {
    HStack(alignment: .center, spacing: 8) {
      Image(systemName: revealed ? "eye" : "eye.slash")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(ModerationPresentation.title(for: ui))
        .appFont(AppTextRole.subheadline)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
      if ui.noOverride {
        Text(ModerationGateText.lockedLabel(for: ui))
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
          .accessibilityHint(ModerationGateText.explanation(for: ui))
      } else {
        Button(revealed ? "Hide" : "Show") {
          setRevealed(!revealed)
        }
        .appFont(AppTextRole.subheadline)
        .buttonStyle(.borderless)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint(revealed ? "Hides the content" : "Shows the content")
        .accessibilityIdentifier("moderation.contentGate.toggle")
      }
    }
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .background(Color(platformColor: .platformSystemGray6), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("moderation.contentGate")
  }

  private func setRevealed(_ isRevealed: Bool) {
    withoutRevealAnimation {
      if storeSubject.isEmpty {
        localReveal = ModerationRevealState(revealing: isRevealed ? ui : nil)
      } else {
        localReveal = nil
        ModerationRevealStore.shared.setRevealed(
          isRevealed, ui: ui, gate: .body, subject: storeSubject, accountDID: appState.userDID)
      }
    }
    invalidateFeedRowHeight?()
  }
}

// MARK: - Media gate

/// Conceals images, galleries, video and link cards behind one cover. The
/// media view is not built while concealed, so nothing loads or plays. Once
/// shown, a small Hide control conceals it again.
struct ModerationMediaGate<Content: View>: View {
  enum Style {
    /// A cover the size of a media block.
    case card
    /// A single-line bar, for thumbnails in dense lists.
    case compact
  }

  let ui: ModerationUI
  var style: Style = .card
  /// Opt in when the media's display ratio is known without building it.
  var reservedAspectRatio: CGFloat? = nil
  @ViewBuilder let content: () -> Content
  /// Show or Hide chosen in this view. `nil` until the viewer chooses, so the
  /// gate starts from `ModerationRevealStore`; setting it re-renders the gate.
  @State private var localReveal: ModerationRevealState?
  @Environment(AppState.self) private var appState
  @Environment(\.postID) private var postID
  @Environment(\.moderationRevealSubject) private var revealSubject
  @Environment(\.invalidateFeedRowHeight) private var invalidateFeedRowHeight

  /// The post `ModerationRevealStore` records this gate's reveal under.
  private var storeSubject: String { revealSubject.isEmpty ? postID : revealSubject }

  private var revealed: Bool {
    if storeSubject.isEmpty {
      return localReveal?.isRevealed(ui) ?? false
    }
    return ModerationRevealStore.shared.isRevealed(
      ui, gate: .media, subject: storeSubject, accountDID: appState.userDID)
  }

  var body: some View {
    Group {
      if !ui.blur {
        content()
      } else if case .card = style, let ratio = reservedAspectRatio, ratio.isFinite, ratio > 0 {
        // Keep the larger of the image and the warning's intrinsic height on
        // both sides of Show/Hide. Only lightweight warning UI is measured while
        // concealed; the media closure is still built exclusively after Show.
        ZStack {
          Color.clear.aspectRatio(ratio, contentMode: .fit)
          cover
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .overlay(alignment: .top) {
          gatedContent.frame(maxHeight: revealed ? nil : .infinity)
        }
      } else {
        gatedContent
      }
    }
    .onChange(of: storeSubject) { _, _ in
      localReveal = nil
    }
  }

  @ViewBuilder
  private var gatedContent: some View {
    if revealed {
      content()
        .overlay(alignment: .topTrailing) { hideControl }
        .postRevealFade(isEnabled: true)
    } else {
      cover
    }
  }

  private var title: String { ModerationPresentation.title(for: ui) }
  private var explanation: String { ModerationGateText.explanation(for: ui) }

  @ViewBuilder
  private var cover: some View {
    switch style {
    case .card:
      // The text is the sized content, so the cover is at least the height of
      // a media block and grows with Dynamic Type instead of clipping.
      VStack(spacing: 6) {
        Image(systemName: "eye.slash.fill")
          .appFont(AppTextRole.title2)
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(title)
          .appFont(AppTextRole.subheadline)
          .fontWeight(.medium)
          .multilineTextAlignment(.center)
        Text(explanation)
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        if !ui.noOverride {
          Button("Show", action: show)
            .appFont(AppTextRole.footnote)
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .padding(.top, 2)
            .accessibilityIdentifier("moderation.mediaGate.show")
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, minHeight: 160)
      .background(Color(platformColor: .platformSystemGray6))
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("moderation.mediaGate")
    case .compact:
      HStack(alignment: .center, spacing: 8) {
        Image(systemName: "eye.slash")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(title)
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
        if ui.noOverride {
          Text(ModerationGateText.lockedLabel(for: ui))
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .accessibilityHint(explanation)
        } else {
          Button("Show", action: show)
            .appFont(AppTextRole.subheadline)
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("moderation.mediaGate.show")
        }
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      .background(Color(platformColor: .platformSystemGray6), in: RoundedRectangle(cornerRadius: 10))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("moderation.mediaGate")
    }
  }

  private var hideControl: some View {
    Button {
      setRevealed(false)
    } label: {
      Label("Hide", systemImage: "eye.slash")
        .appFont(AppTextRole.caption)
        .padding(.horizontal, 10)
        .frame(minHeight: 28)
        .background(Color.black.opacity(0.6), in: Capsule())
        .foregroundStyle(.white)
    }
    .buttonStyle(.plain)
    .padding(8)
    .accessibilityHint("Hides the media again")
    .accessibilityIdentifier("moderation.mediaGate.hide")
  }

  private func show() {
    setRevealed(true)
  }

  private func setRevealed(_ isRevealed: Bool) {
    withoutRevealAnimation {
      if storeSubject.isEmpty {
        localReveal = ModerationRevealState(revealing: isRevealed ? ui : nil)
      } else {
        localReveal = nil
        ModerationRevealStore.shared.setRevealed(
          isRevealed, ui: ui, gate: .media, subject: storeSubject, accountDID: appState.userDID)
      }
    }
    invalidateFeedRowHeight?()
  }
}

// MARK: - Reveal subject

private struct ModerationRevealSubjectKey: EnvironmentKey {
  static let defaultValue = ""
}

extension EnvironmentValues {
  /// The AT URI of the post whose moderation a gate shows, set where a post is
  /// rendered: `PostView`, the thread anchor and a quote card. Body and media
  /// gates record Show and Hide for it in `ModerationRevealStore`, so a reveal
  /// survives cell reuse and applies wherever the same post appears again.
  /// When it is empty a gate uses `\.postID`, and keeps its reveal in view
  /// state only when that is empty too.
  var moderationRevealSubject: String {
    get { self[ModerationRevealSubjectKey.self] }
    set { self[ModerationRevealSubjectKey.self] = newValue }
  }
}

// MARK: - Reveal helpers

private extension ModerationRevealState {
  /// Revealed for `ui`'s causes, or concealed when `ui` is `nil`.
  init(revealing ui: ModerationUI?) {
    self.init()
    if let ui { show(ui) }
  }
}

/// Applies an in-row Show or Hide without SwiftUI, UIKit, or CoreAnimation
/// geometry animation so self-sizing cells step cleanly in one frame.
@MainActor
func withoutRevealAnimation(_ change: () -> Void) {
  var transaction = Transaction(animation: nil)
  transaction.disablesAnimations = true
  #if os(iOS)
  CATransaction.begin()
  CATransaction.setDisableActions(true)
  defer { CATransaction.commit() }
  UIView.performWithoutAnimation {
    withTransaction(transaction, change)
  }
  #else
  withTransaction(transaction, change)
  #endif
}

// MARK: - Shared copy

enum ModerationGateText {
  static let adultContentOffExplanation =
    "Adult content is turned off for this account. You can change this at bsky.app."
  static let moderatorsExplanation = "This content was hidden by the moderators."

  /// The highest-priority blur cause, which a cover or a locked bar names.
  static func primaryCause(of ui: ModerationUI) -> ModerationCause? {
    ui.blurs.min { $0.priority < $1.priority }
  }

  /// Why media is covered and, when it cannot be shown, why not: adult content
  /// turned off (changeable at bsky.app) or a label from the moderators.
  static func explanation(for ui: ModerationUI) -> String {
    guard let cause = primaryCause(of: ui) else { return "" }
    if ui.noOverride {
      return cause.isAdultContentDisabled ? adultContentOffExplanation : moderatorsExplanation
    }
    return ModerationPresentation.description(for: cause.definition)
  }

  /// The short label a locked bar shows in place of Show: who locked it.
  static func lockedLabel(for ui: ModerationUI) -> String {
    primaryCause(of: ui)?.isAdultContentDisabled == true ? "Adult content off" : "Hidden by moderators"
  }

  /// The hidden row's headline, naming who hides the post.
  static func hiddenRowHeadline(for presentation: PostModerationPresentation) -> String {
    switch presentation.hiddenRowReason {
    case .adultContentOff: return "Post hidden while adult content is off"
    case .moderators: return "Post hidden by moderators"
    case .userSetting: return "Post hidden by your moderation settings"
    }
  }

  /// The hidden row's second line: the cause, and where to change an
  /// adult-content lock.
  static func hiddenRowDetail(for presentation: PostModerationPresentation) -> String {
    let title = presentation.hiddenRowCause.map { ModerationPresentation.title(for: $0) }
      ?? ModerationPresentation.fallbackTitle
    switch presentation.hiddenRowReason {
    case .adultContentOff: return "\(title) · Change this at bsky.app"
    case .moderators, .userSetting: return title
    }
  }
}

// MARK: - Avatar placeholder

/// The neutral avatar shown instead of a moderated avatar. The same artwork
/// `AsyncProfileImage` uses while an avatar loads, so no image is fetched.
struct ModeratedAvatarPlaceholder: View {
  let size: CGFloat

  var body: some View {
    Circle()
      .fill(Color.gray.opacity(0.2))
      .overlay {
        Image(systemName: "person.crop.circle.fill")
          .resizable()
          .scaledToFill()
          .foregroundColor(.accentColor.opacity(0.5))
          .padding(size * 0.08)
      }
      .frame(width: size, height: size)
      .clipShape(Circle())
      .accessibilityHidden(true)
  }
}
