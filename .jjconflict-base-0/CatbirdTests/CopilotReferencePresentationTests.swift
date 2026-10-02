import Foundation
import Testing
@testable import Catbird

@MainActor
struct CopilotReferencePresentationTests {
  private let postURI = "at://did:plc:alice/app.bsky.feed.post/abc"
  private let postLink = "https://bsky.app/profile/did:plc:alice/post/abc"

  @Test
  func resolvedReferencesKeepPunctuationAndNavigationIdentity() {
    let source = CopilotSource(label: "Alice: A thoughtful post", uri: postURI)
    let original = "Read \(postURI). Then revisit \(postURI)!"
    let rendered = CopilotReferencePresentation.render(original, sources: [source])

    #expect(String(rendered.characters) == "Read Alice: A thoughtful post. Then revisit Alice: A thoughtful post!")
    #expect(rendered.runs.compactMap { $0.link?.absoluteString } == [postLink, postLink])
    #expect(source.uri == postURI)
  }

  @Test
  func markdownReferenceDisplaysOnceWithResolvedLabel() {
    let source = CopilotSource(label: "Alice: A thoughtful post", uri: postURI)
    let rendered = CopilotReferencePresentation.render("Read [\(postURI)](\(postURI)).", sources: [source])

    #expect(String(rendered.characters) == "Read Alice: A thoughtful post.")
    #expect(rendered.runs.compactMap { $0.link?.absoluteString } == [postLink])
  }

  @Test
  func unresolvedReferencesUseHonestLabelsWithoutLosingLinks() {
    let rawMarkdown = CopilotReferencePresentation.render("[\(postURI)](\(postURI))", sources: [])
    #expect(String(rawMarkdown.characters) == "Post")
    #expect(rawMarkdown.runs.compactMap { $0.link?.absoluteString } == [postLink])

    let readableMarkdown = CopilotReferencePresentation.render("[A thoughtful post](\(postURI))", sources: [])
    #expect(String(readableMarkdown.characters) == "A thoughtful post")

    let profile = CopilotReferencePresentation.render("Ask did:plc:alice.", sources: [])
    #expect(String(profile.characters) == "Ask Profile.")
    #expect(profile.runs.compactMap { $0.link?.absoluteString } == ["https://bsky.app/profile/did:plc:alice"])
  }

  @Test
  func rawMarkdownLabelsWithWebDestinationsRemainSingleReadableLinks() {
    let destination = "https://bsky.app/profile/alice.test/post/abc"
    let source = CopilotSource(label: "Alice: A thoughtful post", uri: postURI)
    let rendered = CopilotReferencePresentation.render("Read [\(postURI)](\(destination)).", sources: [source])
    #expect(String(rendered.characters) == "Read Alice: A thoughtful post.")
    #expect(rendered.runs.compactMap { $0.link?.absoluteString } == [destination])

    let profileDestination = "https://bsky.app/profile/alice.test"
    let profile = CopilotReferencePresentation.render("[did:plc:alice](\(profileDestination))", sources: [])
    #expect(String(profile.characters) == "Profile")
    #expect(profile.runs.compactMap { $0.link?.absoluteString } == [profileDestination])
  }

  @Test
  func legacySourceLabelDoesNotExposeMachineIdentifier() {
    #expect(CopilotReferencePresentation.label(for: CopilotSource(label: postURI, uri: postURI)) == "Post")
  }

  @Test
  func contextUsesActualReadableContent() {
    #expect(CopilotReferencePresentation.contextLabel(.thread(anchorURI: postURI)) == "Thread")
    #expect(CopilotReferencePresentation.contextLabel(.post(
      uri: postURI, cid: nil, authorDID: "did:plc:alice", text: "A thoughtful post"
    )) == "Post: A thoughtful post")
    #expect(CopilotReferencePresentation.contextLabel(.profile(
      did: "did:plc:alice", handle: "alice.test", displayName: "Alice"
    )) == "Profile: Alice")
  }
}
