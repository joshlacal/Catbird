import SwiftUI
import Petrel

struct VerificationInfoSheet: View {
  let kind: VerificationBadgeKind
  let displayName: String
  let verifications: [AppBskyActorDefs.VerificationView]

  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL

  private static let learnMoreURL = URL(string: "https://bsky.social/about/support/verification")!

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          headerBlock
          explanationBlock
          if kind == .regular, !validVerifications.isEmpty {
            sourcesBlock
          }
          actionsBlock
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .navigationTitle(navigationTitle)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Close") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private var validVerifications: [AppBskyActorDefs.VerificationView] {
    verifications.filter { $0.isValid }
  }

  private var navigationTitle: String {
    switch kind {
    case .regular: return "Verified Account"
    case .trustedVerifier: return "Trusted Verifier"
    }
  }

  private var headerBlock: some View {
    HStack(alignment: .center, spacing: 12) {
      VerificationBadgeView(kind: kind)
        .font(.system(size: 36, weight: .semibold))
      VStack(alignment: .leading, spacing: 2) {
        Text(headerTitle)
          .appFont(AppTextRole.title3)
          .fontWeight(.semibold)
        Text(displayName)
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private var headerTitle: String {
    switch kind {
    case .regular: return "Verified account"
    case .trustedVerifier: return "Trusted verifier"
    }
  }

  private var explanationBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(explanationHeadline)
        .appFont(AppTextRole.headline)
      Text(explanationBody)
        .appFont(AppTextRole.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var explanationHeadline: String {
    switch kind {
    case .regular: return "What the checkmark means"
    case .trustedVerifier: return "What the scalloped checkmark means"
    }
  }

  private var explanationBody: String {
    switch kind {
    case .regular:
      return "A blue checkmark indicates that this account has been verified by one or more trusted sources on Bluesky."
    case .trustedVerifier:
      return "A scalloped blue checkmark indicates that this account is a trusted verifier — selected by Bluesky to verify other accounts. Verifications issued by trusted verifiers appear as a blue checkmark on the verified account."
    }
  }

  private var sourcesBlock: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(validVerifications.count == 1 ? "Verified by" : "Verified by \(validVerifications.count) sources")
        .appFont(AppTextRole.headline)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(validVerifications, id: \.uri) { entry in
          verificationRow(entry)
        }
      }
    }
  }

  private func verificationRow(_ entry: AppBskyActorDefs.VerificationView) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.blue)
        .appFont(AppTextRole.body)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.issuer.didString())
          .appFont(AppTextRole.subheadline)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(entry.createdAt.date, format: .dateTime.year().month().day())
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var actionsBlock: some View {
    HStack(spacing: 12) {
      Spacer(minLength: 0)
      Button {
        openURL(Self.learnMoreURL)
      } label: {
        Label("Learn More", systemImage: "arrow.up.right")
          .appFont(AppTextRole.subheadline)
      }
      .buttonStyle(.bordered)
    }
    .padding(.top, 4)
  }
}

#Preview("Regular") {
  Color.clear.sheet(isPresented: .constant(true)) {
    VerificationInfoSheet(
      kind: .regular,
      displayName: "Bluesky",
      verifications: []
    )
  }
}

#Preview("Trusted Verifier") {
  Color.clear.sheet(isPresented: .constant(true)) {
    VerificationInfoSheet(
      kind: .trustedVerifier,
      displayName: "Bluesky",
      verifications: []
    )
  }
}
