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
    // Chips wrap inline; the issuer stays available to VoiceOver and in the label's details.
    LabelChipFlowLayout {
      ForEach(labels) { label in
        let info = AccountLabelPresentation(
          label: label,
          labeler: labelers?.first { $0.creator.did == label.src } ?? loadedLabelers[label.src.didString()]
        )
        Button { onSelectLabel(label) } label: {
          LabelChip(
            title: info.name,
            systemImage: "tag",
            tint: info.severity == .warning ? .orange : .accentColor
          )
          .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // The button stays the accessibility element, so activating it (a VoiceOver double tap)
        // runs its action; a replacement element would drop the action.
        .accessibilityLabel(Text("\(info.name), \(info.attribution)"))
        .accessibilityHint("Opens details for this label")
        .accessibilityIdentifier("profileAccountLabel-\(label.id)")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
