#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
import Vision

@testable import Catbird

@Suite("Main post cell environment")
struct MainPostCellEnvironmentTests {
  @Test("An isolated main post cell renders image ALT badges before and after reuse")
  @MainActor
  func imagePostsRenderWithoutAnOuterSwiftUIEnvironment() async throws {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://example.invalid")))
    let appState = AppState(userDID: "did:plc:mainpostenvironmenttest", client: client)
    appState.themeManager.colorSchemeOverride = .light
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 600, height: 1000)
    window.backgroundColor = .white
    window.overrideUserInterfaceStyle = .light

    // A UIKit root deliberately supplies no SwiftUI environment. The cell's
    // hosting configuration must provide AppState to every post descendant.
    let controller = UIViewController()
    controller.overrideUserInterfaceStyle = .light
    controller.view.backgroundColor = .white
    controller.view.frame = window.bounds
    let cell = MainPostCell(frame: controller.view.bounds)
    cell.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    controller.view.addSubview(cell)
    window.rootViewController = controller
    window.isHidden = false
    defer {
      cell.prepareForReuse()
      let becameKey = window.isKeyWindow
      window.isHidden = true
      window.rootViewController = nil
      if becameKey { previousKeyWindow?.makeKey() }
    }

    let cases = [(1, "SINGLE IMAGE ALPHA"), (4, "FOUR IMAGES BRAVO")]
    for (imageCount, sentinel) in cases {
      cell.prepareForReuse()
      #expect(cell.contentConfiguration == nil)
      let post = try makeImagePost(imageCount: imageCount, text: sentinel)
      cell.traitCollection.performAsCurrent {
        cell.configure(post: post, appState: appState, path: .constant(NavigationPath()))
      }
      #expect(cell.contentConfiguration != nil)

      try await captureAndVerify(cell: cell, window: window, appState: appState, imageCount: imageCount, sentinel: sentinel)
      #expect(controller.presentedViewController == nil, "Rendering the post must not require opening an image viewer")
    }
  }

  @MainActor
  private func captureAndVerify(
    cell: MainPostCell, window: UIWindow, appState: AppState, imageCount: Int, sentinel: String
  ) async throws {
    // ALT overlays must render while opening the post, even if the image is a placeholder.
    let deadline = ContinuousClock.now + .seconds(3)
    var lastPNG = Data()
    var transcript = ""
    var captureError = ""
    var drewHierarchy = false
    var readable = false
    var altBadgeCount = 0
    let captureView = try #require(window.rootViewController?.view)
    repeat {
      try await Task.sleep(for: .milliseconds(50))
      window.layoutIfNeeded()
      window.rootViewController?.view.layoutIfNeeded()
      cell.layoutIfNeeded()
      let format = UIGraphicsImageRendererFormat()
      format.scale = 3
      format.opaque = true
      let image = UIGraphicsImageRenderer(bounds: captureView.bounds, format: format).image { context in
        UIColor.white.setFill()
        context.fill(captureView.bounds)
        captureView.traitCollection.performAsCurrent {
          drewHierarchy = captureView.drawHierarchy(in: captureView.bounds, afterScreenUpdates: true)
        }
      }
      lastPNG = image.pngData() ?? Data()
      do {
        transcript = try recognizeText(in: image)
        altBadgeCount = try countAltBadges(in: image, imageCount: imageCount, transcript: transcript)
        let words = transcript.uppercased().split(whereSeparator: { $0.isWhitespace })
        readable = drewHierarchy
          && words.joined(separator: " ").contains(sentinel)
          && altBadgeCount == imageCount
        captureError = ""
      } catch {
        captureError = String(describing: error)
      }
    } while !readable && ContinuousClock.now < deadline

    if !lastPNG.isEmpty {
      Attachment.record(Array(lastPNG), named: "main-post-\(imageCount)-images-uikit.png")
    }
    let receipt = "imageCount=\(imageCount), altBadgeCount=\(altBadgeCount), drawHierarchy=\(drewHierarchy), readable=\(readable)\n"
      + appearanceReceipt(cell: cell, window: window, appState: appState)
      + "error=\(captureError)\nOCR:\n\(transcript)"
    Attachment.record(Array(receipt.utf8), named: "main-post-\(imageCount)-images-ocr.txt")
    #expect(!lastPNG.isEmpty, "UIKit capture must produce a PNG")
    #expect(drewHierarchy, "UIKit must complete hierarchy capture")
    #expect(readable, "Expected the post text and \(imageCount) ALT badges in captured pixels; see attachments")
  }

  @MainActor
  private func appearanceReceipt(cell: MainPostCell, window: UIWindow, appState: AppState) -> String {
    let color = cell.contentView.backgroundColor?.resolvedColor(with: cell.traitCollection)
    return "fixtureTheme=\(String(describing: appState.themeManager.colorSchemeOverride))\n"
      + "windowStyle=\(window.traitCollection.userInterfaceStyle.rawValue), "
      + "cellStyle=\(cell.traitCollection.userInterfaceStyle.rawValue), "
      + "background=\(String(describing: color))\n"
  }

  private func countAltBadges(in image: UIImage, imageCount: Int, transcript: String) throws -> Int {
    let text: String
    if imageCount > 1 {
      // Vision can collapse identical text on the same row. Read each grid
      // column separately so every visible badge still has to be recognized.
      text = try [CGFloat(0), CGFloat(0.5)].map { originX in
        try recognizeText(in: image, region: CGRect(x: originX, y: 0, width: 0.5, height: 1))
      }.joined(separator: "\n")
    } else {
      text = transcript
    }
    return text.uppercased().split(whereSeparator: { $0.isWhitespace }).filter { $0 == "ALT" }.count
  }

  private func recognizeText(in image: UIImage, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> String {
    let request = VNRecognizeTextRequest()
    request.regionOfInterest = region
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: try #require(image.cgImage), options: [:]).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }

  private func makeImagePost(imageCount: Int, text: String) throws -> AppBskyFeedDefs.PostView {
    let images = (0..<imageCount).map { index in
      // No remote image server or authenticated account is needed by this test.
      let imageURI = URI(uriString: "file:///nonexistent/catbird-main-post-\(index).png")
      return AppBskyEmbedImages.ViewImage(
        thumb: imageURI,
        fullsize: imageURI,
        alt: "Main post regression image \(index + 1)",
        aspectRatio: .init(width: 4, height: 3)
      )
    }
    let record = AppBskyFeedPost(
      text: text,
      entities: nil,
      facets: nil,
      reply: nil,
      embed: nil,
      langs: nil,
      labels: nil,
      tags: nil,
      createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_749_000_000))
    )
    return AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:mainpostauthor/app.bsky.feed.post/images-\(imageCount)"),
      cid: CID.fromDAGCBOR(Data("main-post-images-\(imageCount)".utf8)),
      author: try makeAuthor(),
      record: .knownType(record),
      embed: .appBskyEmbedImagesView(.init(images: images)),
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_749_000_100)),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
  }

  private func makeAuthor() throws -> AppBskyActorDefs.ProfileViewBasic {
    AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: "did:plc:mainpostauthor"),
      handle: try Handle(handleString: "mainpost.example.invalid"),
      displayName: "Image author",
      pronouns: nil,
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
  }
}
#endif
