#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@MainActor
struct ContainerGeometryTests {
  @Test func layoutLimitsFollowTheReceivingViewport() {
    let shapes = [CGSize(width: 320, height: 800), CGSize(width: 1100, height: 700),
      CGSize(width: 800, height: 320), CGSize(width: 440, height: 1100), CGSize(width: 700, height: 700)]
    for size in shapes {
      let width = ContainerLayoutMetrics.drawerWidth(availableWidth: size.width)
      #expect(width > 0 && width <= size.width)
      #expect(ContainerLayoutMetrics.bannerHeight(viewportHeight: size.height) <= size.height * 0.25)
      #expect(ContainerLayoutMetrics.externalMediaHeight(viewportHeight: size.height) <= size.height * 0.6)
    }
    #expect(ContainerLayoutMetrics.drawerWidth(availableWidth: 320) == 320)
    #expect(ContainerLayoutMetrics.drawerWidth(availableWidth: 1100) == 440)
    #expect(ContainerLayoutMetrics.bannerHeight(viewportHeight: 1100) == 200)
    #expect(ContainerLayoutMetrics.externalMediaHeight(viewportHeight: 320) == 192)
    #expect(ContainerLayoutMetrics.drawerWidth(availableWidth: .nan) == 0)
  }

  @Test func composerRemeasuresWithoutReplacingDraftOrSelection() async throws {
    let draft = NSAttributedString(string: String(repeating: "Draft text stays selected as this composer resizes. ", count: 12))
    var textView: UITextView?
    var heights: [CGFloat] = []
    var editor = EnhancedRichTextEditor(
      attributedText: .constant(draft), linkFacets: .constant([]), pendingSelectionRange: .constant(nil),
      placeholder: "Reply", onImagePasted: { _ in }, onGenmojiDetected: { _ in },
      onTextChanged: { _, _ in }, onLinkCreationRequested: { _, _ in })
    editor.onTextViewCreated = { textView = $0 }
    editor.onHeightChange = { heights.append($0) }
    let host = UIHostingController(rootView: editor)
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.rootViewController = host
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 800)
    window.isHidden = false
    defer { window.isHidden = true }
    await settle(window)
    let original = try #require(textView)
    original.selectedRange = NSRange(location: 6, length: 10)
    let originalText = original.attributedText.copy() as! NSAttributedString
    let narrowHeight = try #require(heights.last)
    window.frame = CGRect(x: 0, y: 0, width: 700, height: 700)
    await settle(window)
    #expect(textView === original)
    #expect(original.selectedRange == NSRange(location: 6, length: 10))
    #expect(original.attributedText.isEqual(to: originalText))
    #expect(try #require(heights.last) < narrowHeight)
    window.frame = CGRect(x: 0, y: 0, width: 320, height: 800)
    await settle(window)
    #expect(try #require(heights.last) >= narrowHeight - 1)
    #expect(original.selectedRange == NSRange(location: 6, length: 10))
  }

  @Test func mediaViewportReaderUsesItsOwnWindow() async throws {
    var measured = CGSize.zero
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let host = UIHostingController(rootView: WindowViewportReader { measured = $0 })
    window.rootViewController = host
    window.frame = CGRect(x: 0, y: 0, width: 700, height: 700)
    window.isHidden = false
    defer { window.isHidden = true }
    await settle(window)
    #expect(measured == window.bounds.size)
    let previousHeight = measured.height
    window.frame.size.height = 320
    await settle(window)
    #expect(measured == window.bounds.size)
    #expect(measured.height != previousHeight)
  }

  private func settle(_ window: UIWindow) async {
    for _ in 0..<12 {
      window.setNeedsLayout()
      window.layoutIfNeeded()
      await Task.yield()
    }
  }
}
#endif
