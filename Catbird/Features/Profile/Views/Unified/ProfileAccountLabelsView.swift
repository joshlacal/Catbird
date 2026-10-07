import Petrel
import SwiftUI

/// Applied account labels stay individually visible in another user's profile header.
struct ProfileAccountLabelsView: View {
  @Environment(AppState.self) private var appState

  let labels: [ComAtprotoLabelDefs.Label]
  let viewerDID: String
  let isActiveViewer: @MainActor () -> Bool
  var labelers: [AppBskyLabelerDefs.LabelerViewDetailed]?
  let onSelectLabel: (ComAtprotoLabelDefs.Label) -> Void

  @State private var loadedLabelers: [String: AppBskyLabelerDefs.LabelerViewDetailed] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(labels) { label in
        let info = AccountLabelPresentation(
          label: label,
          labeler: labelers?.first { $0.creator.did == label.src } ?? loadedLabelers[label.src.didString()]
        )
        Button { onSelectLabel(label) } label: {
          HStack(alignment: .top, spacing: 8) {
            Image(systemName: "tag")
              .appFont(AppTextRole.subheadline)
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(info.name)
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(Color.accentColor)
              Text(info.attribution)
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
            }
            .lineLimit(nil)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens details for this label")
        .accessibilityIdentifier("profileAccountLabel-\(label.id)")
      }
    }
    .task(id: metadataRequest) { await loadMetadata(for: metadataRequest) }
  }

  private var metadataRequest: [String] {
    [viewerDID, isActiveViewer() ? "active" : "inactive"] + labels.map(\.id).sorted()
  }

  private var isCurrentViewer: Bool {
    isActiveViewer() && appState.userDID == viewerDID
      && AppStateManager.shared.lifecycle.appState === appState
      && !AppStateManager.shared.authentication.isSwitchingAccount
  }

  private func loadMetadata(for request: [String]) async {
    guard labelers == nil else { return }
    loadedLabelers = [:]
    guard isCurrentViewer, let client = appState.atProtoClient else { return }
    do {
      let issuers = Array(Set(labels.map(\.src))).sorted { $0.didString() < $1.didString() }
      var loaded: [String: AppBskyLabelerDefs.LabelerViewDetailed] = [:]
      for start in stride(from: 0, to: issuers.count, by: 20) {
        try Task.checkCancellation()
        guard isCurrentViewer, request == metadataRequest else { return }
        let batch = Array(issuers[start..<min(start + 20, issuers.count)])
        let (status, output) = try await client.app.bsky.labeler.getServices(input: .init(dids: batch, detailed: true))
        guard !Task.isCancelled, isCurrentViewer, request == metadataRequest else { return }
        guard status == 200, let output else { return }
        for view in output.views {
          if case .appBskyLabelerDefsLabelerViewDetailed(let labeler) = view {
            loaded[labeler.creator.did.didString()] = labeler
          }
        }
      }
      loadedLabelers = loaded
    } catch {
      // Existing presentation keeps identifiers and issuer DIDs visible; the inspector can retry details.
    }
  }
}
