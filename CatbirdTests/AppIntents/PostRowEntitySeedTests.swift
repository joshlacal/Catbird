//
//  PostRowEntitySeedTests.swift
//  CatbirdTests
//
//  Which rendered post rows seed the App Intents resolution stores. Both
//  stores are persisted to the App Group with the post text and the author
//  avatar URL, so moderation decides what a row may store.
//

import Foundation
import Petrel
import Testing

@testable import Catbird

@Suite("Post row entity seed")
struct PostRowEntitySeedTests {
  private typealias F = RenderingFixtures
  private typealias Seed = SpotlightDonationModeration.RowSeed

  /// Adult content on with every media label set to warn, so a media label
  /// blurs without filtering the post from lists.
  private let warnEverything = F.policy(labels: ["porn": "warn", "sexual": "warn", "nudity": "warn", "graphic-media": "warn"])

  @Test("A clean post stores the post and its author")
  func cleanPost() throws {
    let seed = SpotlightDonationModeration.rowSeed(try F.post(embed: F.imageEmbed), policy: F.policy())
    #expect(seed == Seed(storesPost: true, storesAuthor: true))
  }

  @Test("A post lists filter is not stored; its author still is")
  func listFilteredPost() throws {
    // Adult content off filters a porn-labelled post from lists without
    // blurring a text-only body.
    let post = try F.post(labels: [try F.label("porn")])
    let policy = F.policy(adult: false)
    #expect(PostModerationPresentation.make(post: post, policy: policy).isFilteredFromList)
    #expect(!PostModerationPresentation.make(post: post, policy: policy).concealsBody)
    let seed = SpotlightDonationModeration.rowSeed(post, policy: policy)
    #expect(seed == Seed(storesPost: false, storesAuthor: true))
  }

  @Test("A post whose body is gated is not stored")
  func bodyBlurredPost() throws {
    let seed = SpotlightDonationModeration.rowSeed(try F.post(labels: [try F.label("!warn")]), policy: F.policy())
    #expect(seed == Seed(storesPost: false, storesAuthor: true))
  }

  @Test("A post whose media is gated is not stored")
  func mediaBlurredPost() throws {
    let post = try F.post(labels: [try F.label("porn")], embed: F.imageEmbed)
    #expect(!PostModerationPresentation.make(post: post, policy: warnEverything).isFilteredFromList)
    let seed = SpotlightDonationModeration.rowSeed(post, policy: warnEverything)
    #expect(seed == Seed(storesPost: false, storesAuthor: true))
  }

  @Test("An author whose avatar is a placeholder stores neither the post nor the author")
  func avatarBlurredAuthor() throws {
    let author = try F.profile(labels: [try F.accountLabel("porn")])
    let post = try F.post(author: author)
    let presentation = PostModerationPresentation.make(post: post, policy: warnEverything)
    #expect(presentation.concealsAvatar)
    #expect(!presentation.concealsBody && !presentation.concealsMedia && !presentation.isFilteredFromList)
    let seed = SpotlightDonationModeration.rowSeed(post, policy: warnEverything)
    #expect(seed == Seed(storesPost: false, storesAuthor: false))
  }
}
