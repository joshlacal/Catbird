import SwiftUI
import Petrel

enum VerificationBadgeKind: Identifiable {
  case regular
  case trustedVerifier

  var id: Self { self }

  /// SF Symbol name for this badge. Single source of truth shared by
  /// `VerificationBadgeView` (view path) and `VerificationBadge.inlineText`
  /// (composed-`Text` path) so the two never drift.
  var symbolName: String {
    switch self {
    case .regular: return "checkmark.circle.fill"
    case .trustedVerifier: return "checkmark.seal.fill"
    }
  }

  /// VoiceOver label for this badge.
  var accessibilityLabel: String {
    switch self {
    case .regular: return "Verified account"
    case .trustedVerifier: return "Trusted verifier"
    }
  }
}

enum VerificationBadge {
  static let selfVerifiedDID = "did:plc:vc7f4oafdgxsihk4cry2xpze"

  static func kind(
    for state: AppBskyActorDefs.VerificationState?,
    did: DID
  ) -> VerificationBadgeKind? {
    if state?.trustedVerifierStatus == "valid" {
      return .trustedVerifier
    }
    if state?.verifiedStatus == "valid" || did.didString() == selfVerifiedDID {
      return .regular
    }
    return nil
  }

  /// Badge as a composed `Text` segment for inline contexts where a SwiftUI
  /// view can't be embedded (e.g. an `AttributedString`-style sentence built by
  /// concatenating `Text`). Returns `nil` when the actor is not verified.
  ///
  /// The caller is responsible for surfacing the badge to VoiceOver — a bare
  /// `Text(Image(systemName:))` does NOT narrate as "Verified account". Use
  /// `kind(for:did:)?.accessibilityLabel` when composing the container's
  /// `.accessibilityLabel`.
  static func inlineText(
    for state: AppBskyActorDefs.VerificationState?,
    did: DID
  ) -> Text? {
    guard let kind = kind(for: state, did: did) else { return nil }
    return Text(Image(systemName: kind.symbolName)).foregroundColor(.blue)
  }
}

struct VerificationBadgeView: View {
  let kind: VerificationBadgeKind
  var action: (() -> Void)? = nil

  init?(
    verification: AppBskyActorDefs.VerificationState?,
    did: DID,
    action: (() -> Void)? = nil
  ) {
    guard let resolved = VerificationBadge.kind(for: verification, did: did) else {
      return nil
    }
    self.kind = resolved
    self.action = action
  }

  init(kind: VerificationBadgeKind, action: (() -> Void)? = nil) {
    self.kind = kind
    self.action = action
  }

  var body: some View {
    Group {
      if let action {
        Button(action: action) {
          icon
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
      } else {
        icon
      }
    }
    .accessibilityLabel(kind.accessibilityLabel)
  }

  private var icon: some View {
    Image(systemName: kind.symbolName)
      .foregroundStyle(.blue)
  }
}

#Preview {
  HStack(spacing: 16) {
    VerificationBadgeView(kind: .regular)
      .font(.headline)
    VerificationBadgeView(kind: .trustedVerifier)
      .font(.headline)
    VerificationBadgeView(kind: .trustedVerifier, action: {})
      .font(.headline)
  }
  .padding()
}
