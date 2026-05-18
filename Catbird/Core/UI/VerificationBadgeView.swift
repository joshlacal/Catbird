import SwiftUI
import Petrel

enum VerificationBadgeKind: Identifiable {
  case regular
  case trustedVerifier

  var id: Self { self }
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
    .accessibilityLabel(accessibilityLabel)
  }

  private var icon: some View {
    Image(systemName: symbolName)
      .foregroundStyle(.blue)
  }

  private var symbolName: String {
    switch kind {
    case .regular: return "checkmark.circle.fill"
    case .trustedVerifier: return "checkmark.seal.fill"
    }
  }

  private var accessibilityLabel: String {
    switch kind {
    case .regular: return "Verified account"
    case .trustedVerifier: return "Trusted verifier"
    }
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
