import Foundation
import Testing
import Petrel
@testable import Catbird

@Suite("PreviewFixtures decode") struct PreviewFixturesTests {
  @Test func timelineDecodes() {
    let t = PreviewFixtures.timeline
    #expect(t != nil); #expect(!(t?.feed.isEmpty ?? true))
  }
  @Test func everyManifestFixtureIsLoadable() throws {
    let data = try #require(PreviewFixtures.loadData("FixtureManifest"))
    let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let fixtures = try #require(manifest?["fixtures"] as? [String: Any])
    for stem in fixtures.keys { #expect(PreviewFixtures.loadData(stem) != nil, "missing \(stem)") }
  }
  @Test(arguments: PreviewFixtures.PostShape.allCases) func postShape(_ shape: PreviewFixtures.PostShape) {
    // gallery_6 may legitimately be nil if AppView dropped the overlay embed — assert presence for the rest
    if shape != .gallery6 { #expect(PreviewFixtures.post(shape) != nil, "shape \(shape.rawValue)") }
  }
  @Test func embedUnionsCovered() throws {
    let posts = try #require(PreviewFixtures.postShapes?.posts)
    var kinds = Set<String>()
    for p in posts {
      switch p.embed {
      case .appBskyEmbedImagesView: kinds.insert("images")
      case .appBskyEmbedExternalView: kinds.insert("external")
      case .appBskyEmbedRecordView: kinds.insert("record")
      case .appBskyEmbedRecordWithMediaView: kinds.insert("rwm")
      default: break
      }
    }
    #expect(kinds.isSuperset(of: ["images", "external", "record", "rwm"]))
  }
  @Test func notificationsCoverReasons() throws {
    let reasons = Set(try #require(PreviewFixtures.notifications?.notifications).map(\.reason))
    #expect(reasons.isSuperset(of: ["like", "follow", "repost", "reply", "mention", "quote"]))
  }
  @Test func threadV2AndProfilesAndGraphDecode() {
    #expect(PreviewFixtures.threadV2 != nil)
    #expect(PreviewFixtures.profileBot != nil)
    #expect(PreviewFixtures.profileReal != nil)
    #expect(PreviewFixtures.feedGenerators != nil)
    #expect(PreviewFixtures.list != nil)
    #expect(PreviewFixtures.starterPack != nil)
    #expect(PreviewFixtures.labelerServices != nil)
  }
}
