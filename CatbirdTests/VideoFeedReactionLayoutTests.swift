#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// The Vids reaction buttons are touch targets of at least 44 pt. They sit on whole points, so the
/// frames VoiceOver and UI tests read back are exact: a 44 pt button placed on a third of a point
/// (the 3x pixel grid) reads back as 43.999999999999986. Odd and even page widths both occur, so
/// centring is checked on both; accessibility sizes use the row, and `.large` portrait the column.
@MainActor
@Suite("Vids reaction layout", .serialized)
struct VideoFeedReactionLayoutTests {
  private struct Page: Identifiable { let id: Int }

  @Test(
    "Reaction buttons start on whole points and keep their 44 pt minimum exactly",
    arguments: [
      (CGSize(width: 402, height: 874), DynamicTypeSize.accessibility3),
      (CGSize(width: 393, height: 852), .accessibility3),
      (CGSize(width: 440, height: 956), .accessibility3),
      (CGSize(width: 874, height: 402), .accessibility3),
      (CGSize(width: 402, height: 874), .large),
      (CGSize(width: 393, height: 852), .large),
    ]
  )
  func reactionButtonsOnWholePoints(windowSize: CGSize, typeSize: DynamicTypeSize) async throws {
    let restoreAccessibility = AppAccessibility.enable()
    defer { restoreAccessibility() }
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: windowSize)
    var selection: Int? = 0
    // The pager, page overlays and footer the Vids fixture uses.
    let content = VideoFeedPager(
      items: [Page(id: 0), Page(id: 1)], selection: Binding(get: { selection }, set: { selection = $0 })
    ) { _, pageSize in
      ZStack(alignment: .bottom) {
        Color.black
        VideoFeedPageOverlays(status: { VideoFeedPlaybackStatus(state: .paused) {} }, footer: {
          VideoFeedOverlayControls(
            pageSize: pageSize, hasCaption: true,
            author: { _ in
              Text("An author with a long display name").lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            },
            caption: { lines in
              Text("A long caption checks wrapping, larger text, and narrow or resized video pages.")
                .lineLimit(lines).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            },
            actions: { horizontal in
              VideoFeedReactionControls(
                horizontal: horizontal, isLiked: false, isReposted: false, replyCount: 12,
                likeCount: 123, repostCount: 4, canAct: true, onComments: {}, onLike: {}, onRepost: {})
            },
            progress: { VideoProgressBar(currentTime: 15, duration: 60, bufferedTime: 45) { _ in } }
          )
        })
      }
    }
    .dynamicTypeSize(typeSize)
    let host = UIHostingController(rootView: content)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }

    let identifiers = ["videoComments", "videoLike", "videoRepost"]
    var buttons: [AppAccessibility.Element] = []
    // Bounded by wall time: a loaded simulator can take seconds to publish the accessibility tree.
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    repeat {
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(25))
      buttons = AppAccessibility.elements(in: host.view)
        .filter { identifiers.contains($0.identifier ?? "") && host.view.bounds.intersects($0.frame) }
    } while buttons.count < identifiers.count && ContinuousClock.now < deadline
    #expect(Set(buttons.compactMap(\.identifier)) == Set(identifiers))
    for button in buttons {
      let name = button.identifier ?? ""
      #expect(button.frame.minX == button.frame.minX.rounded(), "\(name) starts on a whole point: \(button.frame.minX)")
      #expect(button.frame.minY == button.frame.minY.rounded(), "\(name) starts on a whole point: \(button.frame.minY)")
      #expect(button.frame.width >= 44, "\(name) is at least 44 pt wide: \(button.frame.width)")
      #expect(button.frame.height >= 44, "\(name) is at least 44 pt tall: \(button.frame.height)")
    }
  }
}
#endif
