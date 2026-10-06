//
//  ThreadRowRenderingTests.swift
//  CatbirdTests
//
//  Renders a fixture thread through the production row views in both layout
//  modes. Set THREAD_ROW_SNAPSHOT_DIR (via TEST_RUNNER_THREAD_ROW_SNAPSHOT_DIR
//  for xcodebuild) to also write the renders as PNGs for visual review.
//

import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Thread row rendering")
struct ThreadRowRenderingTests {
  private static let did = "did:plc:renderfixture"

  /// (name, depth, moreReplies, opThread). Parents come from the depth stack.
  private static let fixture: [(String, Int, Int, Bool)] = [
    ("root", -2, 0, false),
    ("parent", -1, 0, false),
    ("anchor", 0, 0, false),
    ("op-continued", 1, 0, true),
    ("first", 1, 0, false),
    ("first-a", 2, 0, false),
    ("first-a-1", 3, 0, false),
    ("first-a-1-x", 4, 0, false),
    ("first-a-1-x-y", 5, 0, false),
    ("first-a-1-x-y-z", 6, 2, false),
    ("first-a-2", 3, 0, false),
    ("first-b", 2, 3, false),
    ("second", 1, 0, false),
    ("second-a", 2, 0, false),
    ("second-b", 2, 0, false)
  ]

  private static let texts: [String: String] = [
    "root": "Where should the thread connectors start and end?",
    "parent": "Every line should land exactly on an avatar centre.",
    "anchor": "This is the anchor post of the fixture thread.",
    "op-continued": "OP continuing their own thread, pinned first.",
    "first": "A top-level reply with a deep subtree.",
    "first-a": "Depth two: indented one step, on the parent's rail.",
    "first-a-1": "Depth three.",
    "first-a-1-x": "Depth four.",
    "first-a-1-x-y": "Depth five.",
    "first-a-1-x-y-z": "Depth six, the compact indent cap.",
    "first-a-2": "A later sibling at depth three keeps the depth-two rail alive.",
    "first-b": "Last sibling at depth two ends the rail in its elbow.",
    "second": "A second branch after a divider.",
    "second-a": "Sibling one.",
    "second-b": "Sibling two."
  ]

  private func threadItems() throws -> [AppBskyUnspeccedGetPostThreadV2.ThreadItem] {
    try Self.fixture.map { name, depth, moreReplies, opThread in
      let post = PublicPostTestFixtures.makePostView(
        uri: try ATProtocolURI(uriString: "at://\(Self.did)/app.bsky.feed.post/\(name)"),
        authorDID: try DID(didString: Self.did),
        text: Self.texts[name] ?? name
      )
      return AppBskyUnspeccedGetPostThreadV2.ThreadItem(
        uri: post.uri,
        depth: depth,
        value: .appBskyUnspeccedDefsThreadItemPost(
          AppBskyUnspeccedDefs.ThreadItemPost(
            post: post,
            moreParents: false,
            moreReplies: moreReplies,
            opThread: opThread,
            opThreadPostIndex: nil,
            opThreadPostCount: nil,
            hiddenByThreadgate: false,
            mutedByViewer: false
          ))
      )
    }
  }

  private func render(mode: ThreadLayoutMode) async throws -> UIImage {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    let items = try threadItems()
    let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.uri.uriString(), $0) })
    let rows = ThreadRowBuilder.build(
      items: items.map(ThreadRowBuilder.Item.init),
      mode: mode,
      maxIndentLevels: ThreadReplyGeometry.compactMaxIndentLevels
    )

    let path = Binding.constant(NavigationPath())
    let content = VStack(spacing: 0) {
      ForEach(rows) { row in
        if row.kind == .anchor, let post = itemsByID[row.id]?.post {
          ThreadAnchorPostView(post: post, showsLineFromParent: row.lineIn, path: path, appState: appState)
        } else {
          ThreadRowView(
            row: row,
            threadItem: itemsByID[row.id],
            parentAuthor: row.parentID.flatMap { itemsByID[$0]?.post?.author },
            path: path,
            appState: appState
          )
        }
      }
    }
    .applyAppStateEnvironment(appState).environment(SceneNavigationContext(appState: appState, sceneID: UUID()))
    .background(Color(uiColor: .systemBackground))

    let width: CGFloat = 402
    let controller = UIHostingController(rootView: content)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 800))
    window.rootViewController = controller
    window.isHidden = false
    let height = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    window.frame = CGRect(x: 0, y: 0, width: width, height: height)
    controller.view.frame = window.bounds
    controller.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(300))

    let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
    let image = renderer.image { _ in
      controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
    }
    window.isHidden = true

    if let directory = ProcessInfo.processInfo.environment["THREAD_ROW_SNAPSHOT_DIR"] {
      let url = URL(fileURLWithPath: directory).appendingPathComponent("thread-\(mode.rawValue).png")
      try image.pngData()?.write(to: url)
    }
    return image
  }

  @Test("Fixture thread renders in both layout modes", arguments: [ThreadLayoutMode.linear, .tree])
  func rendersFixtureThread(mode: ThreadLayoutMode) async throws {
    let image = try await render(mode: mode)
    #expect(image.size.width == 402)
    #expect(image.size.height > 400)
  }
}
