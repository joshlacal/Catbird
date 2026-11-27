import Foundation
import Petrel
import Testing
@testable import Catbird

struct AskCatbirdPostRefsTests {
  private let first = "at://did:plc:alice/app.bsky.feed.post/aaa"
  private let second = "at://did:plc:bob/app.bsky.feed.post/bbb"

  @Test func assignsStableShortIdsAndResolvesThem() throws {
    let refs = AskCatbirdPostRefs()
    #expect(refs.ref(for: first) == "p1")
    #expect(refs.ref(for: second) == "p2")
    #expect(refs.ref(for: first) == "p1")
    #expect(refs.resolve(" P2 ") == second)
    #expect(refs.resolve("p9") == "p9")
    #expect(refs.resolve(first) == first)
    #expect(try AskCatbirdToolPolicy.postURI(refs.resolve("p1")).uriString() == first)
  }

  @Test func expandsOnlyKnownIdsInJSONValues() {
    let refs = AskCatbirdPostRefs()
    _ = refs.ref(for: first)
    let json = #"{"id":"p1","replyTo":"p7","text":"He said \"p1\" twice","note":"p1 is fine"}"#
    let expanded = refs.expandJSON(json)
    #expect(expanded.contains(#""id":"\#(first)""#))
    #expect(expanded.contains(#""replyTo":"p7""#))
    #expect(expanded.contains(#""text":"He said \"p1\" twice""#))
    #expect(expanded.contains(#""note":"p1 is fine""#))
    #expect((try? JSONSerialization.jsonObject(with: Data(expanded.utf8))) != nil)
  }

  @Test func expandsCitedIdsButNotWordsThatLookLikeThem() {
    let refs = AskCatbirdPostRefs()
    _ = refs.ref(for: first)
    _ = refs.ref(for: second)
    let answer = "[@alice](p1) disagrees with @bob (p2). Step p1x, help, p3 and p12 stay; see p2."
    #expect(refs.expandAnswer(answer) ==
      "[@alice](\(first)) disagrees with @bob (\(second)). Step p1x, help, p3 and p12 stay; see \(second).")
  }

  @Test func streamedAnswerNeverRewritesShownTextWhenAnIdGrows() {
    let refs = AskCatbirdPostRefs()
    for index in 1...12 { _ = refs.ref(for: "at://did:plc:x/app.bsky.feed.post/\(index)") }
    var stream = AskCatbirdRefStream(refs: refs)
    var shown = ""
    for snapshot in ["See [it](p", "See [it](p1", "See [it](p12", "See [it](p12) and p", "See [it](p12) and p3"] {
      shown += stream.next(snapshot)
    }
    #expect(shown == "See [it](at://did:plc:x/app.bsky.feed.post/12) and ")
    shown += stream.finish("See [it](p12) and p3")
    #expect(shown == "See [it](at://did:plc:x/app.bsky.feed.post/12) and at://did:plc:x/app.bsky.feed.post/3")
  }

  @Test func streamPassesThroughOrdinaryWordsImmediately() {
    var stream = AskCatbirdRefStream(refs: AskCatbirdPostRefs())
    #expect(stream.next("help") == "help")
    #expect(stream.next("help step") == " step")
    #expect(stream.finish("help step") == "")
  }
}
