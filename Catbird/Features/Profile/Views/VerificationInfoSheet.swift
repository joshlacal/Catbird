import SwiftUI
import Petrel

struct VerificationInfoSheet: View {
  let kind: VerificationBadgeKind
  let displayName: String
  let verifications: [AppBskyActorDefs.VerificationView]

  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @Environment(AppState.self) private var appState
  @State private var resolvedHandles: [String: String] = [:]

  private static let learnMoreURL = URL(string: "https://bsky.social/about/blog/04-21-2025-verification")!

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

  private var navigationTitle: LocalizedStringResource {
    switch kind {
    case .regular:
      return LocalizedStringResource("Verified Account", comment: "Navigation title for the verified account info sheet.")
    case .trustedVerifier:
      return LocalizedStringResource("Trusted Verifier", comment: "Navigation title for the trusted verifier info sheet.")
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

  private var headerTitle: LocalizedStringResource {
    switch kind {
    case .regular:
      return LocalizedStringResource("Verified account", comment: "Header title describing a verified account.")
    case .trustedVerifier:
      return LocalizedStringResource("Trusted verifier", comment: "Header title describing a trusted verifier account.")
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

  private var explanationHeadline: LocalizedStringResource {
    switch kind {
    case .regular:
      return LocalizedStringResource("What the checkmark means", comment: "Section heading explaining the regular verification badge.")
    case .trustedVerifier:
      return LocalizedStringResource("What the scalloped checkmark means", comment: "Section heading explaining the trusted verifier badge.")
    }
  }

  private var explanationBody: LocalizedStringResource {
    switch kind {
    case .regular:
      return LocalizedStringResource(
        "A blue checkmark indicates that this account has been verified by one or more trusted sources on Bluesky.",
        comment: "Explanation body for a verified account badge."
      )
    case .trustedVerifier:
      return LocalizedStringResource(
        "A scalloped blue checkmark indicates that this account is a trusted verifier — selected by Bluesky to verify other accounts. Verifications issued by trusted verifiers appear as a blue checkmark on the verified account.",
        comment: "Explanation body for a trusted verifier badge."
      )
    }
  }

  private var sourcesBlock: some View {
    VStack(alignment: .leading, spacing: 12) {
      if validVerifications.dropFirst().isEmpty {
        Text("Verified by", comment: "Section heading above a single verification source.")
          .appFont(AppTextRole.headline)
      } else {
        Text("Verified by \(validVerifications.count) sources", comment: "Section heading above multiple verification sources — %1$lld is the number of sources.")
          .appFont(AppTextRole.headline)
      }
      VStack(alignment: .leading, spacing: 8) {
        ForEach(validVerifications, id: \.uri) { entry in
          verificationRow(entry)
        }
      }
    }
  }

  private func verificationRow(_ entry: AppBskyActorDefs.VerificationView) -> some View {
    let did = entry.issuer.didString()
    let handle = resolvedHandles[did]
    return HStack(alignment: .top, spacing: 10) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.blue)
        .appFont(AppTextRole.body)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: handle.map { "@\($0)" } ?? truncated(did))
          .appFont(AppTextRole.subheadline)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(entry.createdAt.date, format: .dateTime.year().month().day())
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }
    }
    .task(id: did) {
      await resolveHandle(forDID: did)
    }
  }

  private func truncated(_ did: String) -> String {
    guard did.count > 20 else { return did }
    let prefix = did.prefix(12)
    let suffix = did.suffix(6)
    return "\(prefix)…\(suffix)"
  }

  private func resolveHandle(forDID did: String) async {
    if resolvedHandles[did] != nil { return }
    guard let client = appState.atProtoClient else { return }
    guard let identifier = try? ATIdentifier(string: did) else { return }
    guard let params = try? AppBskyActorGetProfile.Parameters(actor: identifier) else { return }
    do {
      let (code, profile) = try await client.app.bsky.actor.getProfile(input: params)
      guard code == 200, let profile else { return }
      let handle = profile.handle.description
      await MainActor.run {
        resolvedHandles[did] = handle
      }
    } catch {
      // Resolution failure is non-fatal; keep showing the truncated DID.
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
      .buttonStyle(.catbird(.tonal, size: .md))
    }
    .padding(.top, 4)
  }
}

#Preview("Regular") {
  Color.clear
    .sheet(isPresented: .constant(true)) {
      VerificationInfoSheet(
        kind: .regular,
        displayName: "Bluesky",
        verifications: []
      )
    }
    .previewWithMockEnvironment()
}

#Preview("Trusted Verifier") {
  Color.clear
    .sheet(isPresented: .constant(true)) {
      VerificationInfoSheet(
        kind: .trustedVerifier,
        displayName: "Bluesky",
        verifications: []
      )
    }
    .previewWithMockEnvironment()
}
