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
    did: DID,
    hideBadges: Bool = false
  ) -> VerificationBadgeKind? {
    guard !hideBadges else { return nil }
    if state?.trustedVerifierStatus == "valid" {
      return .trustedVerifier
    }
    if state?.verifiedStatus == "valid" || did.didString() == selfVerifiedDID {
      return .regular
    }
    return nil
  }

  /// Embedded authors require server verification metadata. Identity alone does
  /// not establish verification, including the legacy self-verified fallback.
  static func metadataKind(
    for state: AppBskyActorDefs.VerificationState?,
    hideBadges: Bool = false
  ) -> VerificationBadgeKind? {
    guard !hideBadges else { return nil }
    if state?.trustedVerifierStatus == "valid" { return .trustedVerifier }
    if state?.verifiedStatus == "valid" { return .regular }
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
    did: DID,
    hideBadges: Bool = false
  ) -> Text? {
    guard let kind = kind(for: state, did: did, hideBadges: hideBadges) else { return nil }
    return Text(Image(systemName: kind.symbolName)).foregroundColor(.blue)
  }
}

struct VerificationBadgeView: View {
  @Environment(AppState.self) private var appState: AppState?
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
    if appState?.preferencesManager.hideVerificationBadges == true {
      EmptyView()
    } else {
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

/// Automation is an actor's own disclosure, independent of verification or moderation labels.
enum AutomationBadge {
  static let accessibilityLabel = String(localized: "Automated account")

  static func isSelfDeclared(
    labels: [ComAtprotoLabelDefs.Label]?,
    authorDID: DID
  ) -> Bool {
    labels?.contains { $0.val == "bot" && $0.src == authorDID } ?? false
  }
}

/// Original monochrome vector; cutouts remain transparent in every theme.
private struct RobotHeadShape: Shape {
  func path(in rect: CGRect) -> Path {
    let side = min(rect.width, rect.height)
    let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
    func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
      CGRect(x: origin.x + x * side, y: origin.y + y * side, width: width * side, height: height * side)
    }
    var path = Path()
    path.addRoundedRect(in: box(0.17, 0.30, 0.66, 0.58), cornerSize: CGSize(width: side * 0.12, height: side * 0.12))
    path.addRect(box(0.46, 0.17, 0.08, 0.13))
    path.addEllipse(in: box(0.43, 0.03, 0.14, 0.14))
    path.addRoundedRect(in: box(0.04, 0.46, 0.13, 0.24), cornerSize: CGSize(width: side * 0.04, height: side * 0.04))
    path.addRoundedRect(in: box(0.83, 0.46, 0.13, 0.24), cornerSize: CGSize(width: side * 0.04, height: side * 0.04))
    path.addEllipse(in: box(0.31, 0.47, 0.11, 0.11))
    path.addEllipse(in: box(0.58, 0.47, 0.11, 0.11))
    path.addRoundedRect(in: box(0.35, 0.71, 0.30, 0.06), cornerSize: CGSize(width: side * 0.02, height: side * 0.02))
    return path
  }
}

struct AutomationBadgeView: View {
  @ScaledMetric private var side: CGFloat

  init(size: CGFloat = 13, relativeTo textStyle: Font.TextStyle = .body) {
    _side = ScaledMetric(wrappedValue: size, relativeTo: textStyle)
  }

  var body: some View {
    RobotHeadShape()
      .fill(style: FillStyle(eoFill: true))
      .foregroundStyle(.secondary)
      .frame(width: side, height: side)
      .fixedSize()
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(AutomationBadge.accessibilityLabel)
  }
}

#Preview("Automation beside names") {
  VStack(alignment: .leading, spacing: 12) {
    HStack(spacing: 4) {
      Text("Weather updates")
      AutomationBadgeView()
    }
    HStack(spacing: 4) {
      Text("Verified automated account")
      VerificationBadgeView(kind: .regular)
      AutomationBadgeView()
    }
    HStack(spacing: 4) {
      Text("@automated.example")
      AutomationBadgeView(size: 18, relativeTo: .headline)
    }
    .font(.headline)
  }
  .padding()
}
