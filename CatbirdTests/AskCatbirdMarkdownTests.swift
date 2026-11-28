import Foundation
import Testing
@testable import Catbird

struct AskCatbirdMarkdownTests {
  @Test func parsesHeadingsListsQuotesCodeAndParagraphs() {
    let text = """
    ### What happened
    **Alice** posted a claim.
    It spread quickly.

    - First point
      continues here
    - Second point
      - Nested point
    1. Step one
    2) Step two

    > A quoted line

    ```
    let x = 1
    ```
    ---
    Done.
    """
    #expect(AskCatbirdMarkdown.parse(text) == [
      .heading(level: 3, text: "What happened"),
      .paragraph("**Alice** posted a claim.\nIt spread quickly."),
      .bullet(indent: 0, text: "First point\ncontinues here"),
      .bullet(indent: 0, text: "Second point"),
      .bullet(indent: 1, text: "Nested point"),
      .numbered(indent: 0, number: "1", text: "Step one"),
      .numbered(indent: 0, number: "2", text: "Step two"),
      .quote("A quoted line"),
      .code("let x = 1"),
      .divider,
      .paragraph("Done.")
    ])
  }

  @Test func plainTextAndEmphasisAreNotMistakenForBlocks() {
    #expect(AskCatbirdMarkdown.parse("#hashtag and *emphasis* stay inline") == [
      .paragraph("#hashtag and *emphasis* stay inline")
    ])
    #expect(AskCatbirdMarkdown.parse("**Bold start** of a line") == [.paragraph("**Bold start** of a line")])
  }

  @Test func unterminatedCodeFenceWhileStreamingKeepsItsText() {
    #expect(AskCatbirdMarkdown.parse("Intro\n```\npartial") == [.paragraph("Intro"), .code("partial")])
  }

  @Test func inlineRendersEmphasisAndOnlyWebLinks() {
    let rendered = AskCatbirdMarkdown.inline("**Bold** [site](https://example.com) [x](javascript:alert(1)) see example.org")
    #expect(String(rendered.characters) == "Bold site x see example.org")
    let links = rendered.runs.compactMap(\.link).map(\.absoluteString)
    #expect(links.contains("https://example.com"))
    #expect(links.contains { $0.contains("example.org") })
    #expect(!links.contains { $0.hasPrefix("javascript") })
    let bold = rendered.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
    #expect(bold)
  }

  @Test func referencesStillLinkInsideMarkdownAnswers() {
    let uri = "at://did:plc:example/app.bsky.feed.post/abc"
    let rendered = CopilotReferencePresentation.render(
      "**Key:** [@alice](\(uri)) said so", sources: [CopilotSource(label: "@alice: said so", uri: uri)]
    )
    let text = String(rendered.characters)
    #expect(text.hasPrefix("Key: "))
    #expect(!text.contains("at://") && !text.contains("**"))
    #expect(rendered.runs.contains { $0.link?.absoluteString == "https://bsky.app/profile/did:plc:example/post/abc" })
  }

  @Test func contextLabelsKeepAuthoredAsterisks() {
    let label = CopilotReferencePresentation.contextLabel(.search(query: "*literal*"))
    #expect(label == "Search: *literal*")
  }
}
