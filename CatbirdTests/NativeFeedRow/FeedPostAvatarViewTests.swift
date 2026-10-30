#if os(iOS)
import Nuke
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Feed post avatar view")
struct FeedPostAvatarViewTests {
  private func solidImage(_ color: UIColor, side: CGFloat = 8) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
      color.setFill()
      context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
  }

  @Test("An image that arrives after reuse is not shown")
  func lateImageIgnored() async throws {
    let view = FeedPostAvatarView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    view.configure(url: URL(string: "https://example.com/a.jpg"), pointSize: 48, scale: 2, accessibilityName: "A")
    let staleToken = view.currentRequestToken
    view.prepareForReuse()
    view.configure(url: nil, pointSize: 48, scale: 2, accessibilityName: "B")
    view.deliver(UIImage(systemName: "star")!, forToken: staleToken)
    #expect(view.displayedImage == nil)
  }

  @Test("An image that arrives for a newer configure of the same view is not shown")
  func lateImageIgnoredWithoutReuse() {
    let view = FeedPostAvatarView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    view.configure(url: URL(string: "https://example.com/first.jpg"), pointSize: 48, scale: 2, accessibilityName: "A")
    let staleToken = view.currentRequestToken
    view.configure(url: URL(string: "https://example.com/second.jpg"), pointSize: 48, scale: 2, accessibilityName: "B")
    view.deliver(solidImage(.red), forToken: staleToken)
    #expect(view.displayedImage == nil)
  }

  @Test("An image delivered for the current request is shown")
  func currentImageShown() {
    let view = FeedPostAvatarView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    view.configure(url: URL(string: "https://example.com/a.jpg"), pointSize: 48, scale: 2, accessibilityName: "A")
    let image = solidImage(.blue)
    view.deliver(image, forToken: view.currentRequestToken)
    #expect(view.displayedImage === image)
  }

  @Test("Reuse clears the image, the tap handler and the in-flight request")
  func reuseResetsState() {
    let view = FeedPostAvatarView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    view.configure(url: URL(string: "https://example.com/a.jpg"), pointSize: 48, scale: 2, accessibilityName: "A")
    view.onTap = {}
    view.deliver(solidImage(.green), forToken: view.currentRequestToken)
    let before = view.currentRequestToken
    view.prepareForReuse()
    #expect(view.displayedImage == nil)
    #expect(view.onTap == nil)
    #expect(view.currentRequestToken != before)
  }

  @Test("Configuring a new post drops the previous post's image")
  func configureDropsPreviousImage() {
    let view = FeedPostAvatarView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    view.configure(url: URL(string: "https://example.com/a.jpg"), pointSize: 48, scale: 2, accessibilityName: "A")
    view.deliver(solidImage(.green), forToken: view.currentRequestToken)
    view.configure(url: URL(string: "https://example.com/b.jpg"), pointSize: 48, scale: 2, accessibilityName: "B")
    #expect(view.displayedImage == nil)
  }

  @Test("A memory-cached avatar is shown synchronously")
  func memoryCacheHit() throws {
    let url = try #require(URL(string: "https://example.com/avatar-cache-hit-\(UUID().uuidString).jpg"))
    let request = try #require(ImageRequestFactory.avatar(url, pointSize: 48, scale: 2))
    let pipeline = ImageLoadingManager.shared.pipeline
    let image = solidImage(.orange)
    pipeline.cache[request] = ImageContainer(image: image)
    defer { pipeline.cache[request] = nil }

    let view = FeedPostAvatarView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    view.configure(url: url, pointSize: 48, scale: 2, accessibilityName: "A")
    #expect(view.displayedImage === image)
  }

  @Test("A post without an avatar shows the person glyph and no image")
  func noAvatarShowsPlaceholder() {
    let view = FeedPostAvatarView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    view.configure(url: nil, pointSize: 48, scale: 2, accessibilityName: "A")
    #expect(view.displayedImage == nil)
    #expect(view.isShowingPlaceholderGlyph)
    view.configure(url: URL(string: "https://example.com/a.jpg"), pointSize: 48, scale: 2, accessibilityName: "A")
    #expect(!view.isShowingPlaceholderGlyph)
  }

  @Test("VoiceOver reads the author and the profile action")
  func accessibility() {
    let view = FeedPostAvatarView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    view.configure(url: nil, pointSize: 48, scale: 2, accessibilityName: "Alice Rivera")
    #expect(view.isAccessibilityElement)
    #expect(view.accessibilityLabel == "Alice Rivera, view profile")
    #expect(view.accessibilityTraits.contains(.button))
  }

  @Test("The avatar is clipped to a circle")
  func circularClip() throws {
    let view = FeedPostAvatarView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    view.configure(url: URL(string: "https://example.com/a.jpg"), pointSize: 48, scale: 2, accessibilityName: "A")
    view.deliver(solidImage(.red, side: 48), forToken: view.currentRequestToken)
    view.setNeedsLayout()
    view.layoutIfNeeded()
    let pixels = try RenderedPixels(of: view, scale: 2)
    let center = pixels.color(at: CGPoint(x: 24, y: 24))
    #expect(center.isSolidRed)
    #expect(pixels.color(at: CGPoint(x: 1, y: 1)).isNearWhite)
    #expect(pixels.color(at: CGPoint(x: 24, y: 1)).isSolidRed)
  }

  @Test("Activating the avatar from VoiceOver runs the tap handler")
  func voiceOverActivation() {
    let view = FeedPostAvatarView(frame: CGRect(x: 0, y: 0, width: 48, height: 48))
    var taps = 0
    #expect(!view.accessibilityActivate())
    view.onTap = { taps += 1 }
    #expect(view.accessibilityActivate())
    #expect(taps == 1)
  }
}
#endif
