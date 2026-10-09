import SwiftUI

/// Keeps the originating section's namespace with its route, including when the
/// thumbnail lives in a UIHostingConfiguration. The route owns no view/player.
@MainActor
public final class VideoFeedZoomSource: Hashable {
  public nonisolated let sectionID: UUID
  public nonisolated let postURI: String?
  let namespace: Namespace.ID

  init(sectionID: UUID, postURI: String?, namespace: Namespace.ID) {
    self.sectionID = sectionID
    self.postURI = postURI
    self.namespace = namespace
  }

  var sourceID: String { Self.sourceID(for: postURI) }

  nonisolated static func sourceID(for postURI: String?) -> String {
    postURI ?? "the-vids-entry"
  }

  public nonisolated static func == (lhs: VideoFeedZoomSource, rhs: VideoFeedZoomSource) -> Bool {
    lhs.sectionID == rhs.sectionID && lhs.postURI == rhs.postURI
  }

  public nonisolated func hash(into hasher: inout Hasher) {
    hasher.combine(sectionID)
    hasher.combine(postURI)
  }
}

extension View {
  @MainActor
  @ViewBuilder
  func videoFeedZoomSource(postURI: String?, namespace: Namespace.ID, cornerRadius: CGFloat) -> some View {
    #if os(iOS)
    if #available(iOS 18.0, macOS 15.0, *) {
      matchedTransitionSource(id: VideoFeedZoomSource.sourceID(for: postURI), in: namespace) { source in
        source.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
      }
    } else {
      self
    }
    #else
    self
    #endif
  }

  nonisolated func videoFeedZoomDestination(_ source: VideoFeedZoomSource) -> some View {
    modifier(VideoFeedZoomDestinationModifier(source: source))
  }
}

private struct VideoFeedZoomDestinationModifier: ViewModifier {
  let source: VideoFeedZoomSource

  // Constructing this value stores only a Sendable main-actor reference.
  // Namespace access remains in SwiftUI's main-actor body evaluation.
  nonisolated init(source: VideoFeedZoomSource) {
    self.source = source
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    #if os(iOS)
    if #available(iOS 18.0, macOS 15.0, *) {
      // Reduce Motion chooses the existing route at the tap site. Keep this modifier
      // stable during presentation so a settings change cannot recreate the player.
      // Keep the launch source fixed while paging. SwiftUI resolves the matching
      // source again on return. Post URI prevents a reused card showing another
      // video from becoming the destination; absent sources use native handling.
      content.navigationTransition(.zoom(sourceID: source.sourceID, in: source.namespace))
    } else {
      content
    }
    #else
    content
    #endif
  }
}
