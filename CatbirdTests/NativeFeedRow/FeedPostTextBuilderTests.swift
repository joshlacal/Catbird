#if os(iOS)
import Foundation
import Petrel
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Feed post text builder")
struct FeedPostTextBuilderTests {
  private func post(_ text: String, facets: [AppBskyRichtextFacet]? = nil) -> AppBskyFeedPost {
    AppBskyFeedPost(
      text: text, entities: nil, facets: facets, reply: nil, embed: nil, langs: nil, labels: nil,
      tags: nil, createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 0)))
  }

  private func mention(_ did: String, start: Int, end: Int) throws -> AppBskyRichtextFacet {
    AppBskyRichtextFacet(
      index: AppBskyRichtextFacet.ByteSlice(byteStart: start, byteEnd: end),
      features: [.appBskyRichtextFacetMention(AppBskyRichtextFacet.Mention(did: try DID(didString: did)))])
  }

  private var typography: FeedRowTypography {
    FeedRowTypography.resolved(
      fontManager: FontManager(), boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory)
  }

  private func typography(lineSpacing: String, fontManager: FontManager) -> FeedRowTypography {
    fontManager.lineSpacing = lineSpacing
    return FeedRowTypography.resolved(
      fontManager: fontManager, boldText: false, contentSize: UIApplication.shared.preferredContentSizeCategory)
  }

  private func linkedText(in built: NSAttributedString) -> String {
    var linked = ""
    built.enumerateAttribute(.feedLink, in: NSRange(location: 0, length: built.length)) { value, range, _ in
      if value != nil { linked += (built.string as NSString).substring(with: range) }
    }
    return linked
  }

  @Test("Mention facets become feedLink runs over the same characters")
  func mentionLinked() throws {
    let text = "hi @alice.test!"
    let built = FeedPostTextBuilder.build(
      post: post(text, facets: [try mention("did:plc:alice", start: 3, end: 14)]),
      typography: typography, linkStyle: .color, textColor: .label, linkColor: .systemBlue)
    #expect(linkedText(in: built) == "@alice.test")
    let url = built.attribute(.feedLink, at: 3, effectiveRange: nil) as? URL
    #expect(url?.absoluteString.hasPrefix("mention://") == true)
  }

  @Test("Multi-unit characters before a facet do not shift the linked range")
  func emojiBeforeMention() throws {
    let prefix = "👩🏽‍💻 "
    let handle = "@alice.test"
    let start = prefix.utf8.count
    let built = FeedPostTextBuilder.build(
      post: post(prefix + handle + "!", facets: [try mention("did:plc:alice", start: start, end: start + handle.utf8.count)]),
      typography: typography, linkStyle: .color, textColor: .label, linkColor: .systemBlue)
    #expect(linkedText(in: built) == handle)
    #expect(built.attribute(.feedLink, at: (prefix as NSString).length, effectiveRange: nil) != nil)
    #expect(built.attribute(.feedLink, at: 0, effectiveRange: nil) == nil)
  }

  @Test("Link style controls color and underline")
  func linkStyles() throws {
    let facet = try mention("did:plc:alice", start: 0, end: 6)
    let underlined = FeedPostTextBuilder.build(
      post: post("@alice", facets: [facet]), typography: typography, linkStyle: .underline,
      textColor: .label, linkColor: .systemBlue)
    #expect(underlined.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    #expect(underlined.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .label)
    let disabled = FeedPostTextBuilder.build(
      post: post("@alice", facets: [facet]), typography: typography, linkStyle: .disabled,
      textColor: .label, linkColor: .systemBlue)
    #expect(disabled.attribute(.feedLink, at: 0, effectiveRange: nil) != nil)
    #expect(disabled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .label)
  }

  @Test("Body font, line spacing and kerning apply to the whole string")
  func bodyAttributes() {
    let built = FeedPostTextBuilder.build(
      post: post("plain text"), typography: typography, linkStyle: .color, textColor: .label, linkColor: .systemBlue)
    #expect(built.attribute(.font, at: 4, effectiveRange: nil) as? UIFont == typography.body)
    #expect(built.attribute(.kern, at: 4, effectiveRange: nil) as? CGFloat == typography.kerning)
    let paragraph = built.attribute(.paragraphStyle, at: 4, effectiveRange: nil) as? NSParagraphStyle
    #expect(paragraph?.lineSpacing == typography.bodyLineSpacing)
    // Normal lines take the font's own height.
    #expect(paragraph?.minimumLineHeight == 0)
    #expect(paragraph?.maximumLineHeight == 0)
  }

  @Test("At Tight every line has the constant line height and no extra spacing",
    .enabled(if: FontManager.supportsLineHeight))
  func tightParagraphHasConstantLineHeight() throws {
    let fontManager = FontManager()
    let tight = typography(lineSpacing: "tight", fontManager: fontManager)
    let line = try #require(tight.bodyLine)
    let built = FeedPostTextBuilder.build(
      post: post("first line\nsecond line"), typography: tight, linkStyle: .color, textColor: .label,
      linkColor: .systemBlue)
    let paragraph = try #require(built.attribute(.paragraphStyle, at: 12, effectiveRange: nil) as? NSParagraphStyle)
    #expect(paragraph.minimumLineHeight == line.lineHeight)
    #expect(paragraph.maximumLineHeight == line.lineHeight)
    #expect(paragraph.lineSpacing == 0)
    #expect(paragraph.lineBreakMode == .byWordWrapping)
  }
}
#endif
