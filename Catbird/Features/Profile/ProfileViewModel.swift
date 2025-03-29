import Foundation
import OSLog
import Observation
import Petrel
import SwiftUI

@Observable final class ProfileViewModel {
  // MARK: - Properties

  // Profile data
  private(set) var profile: AppBskyActorDefs.ProfileViewDetailed?
  private(set) var posts: [AppBskyFeedDefs.FeedViewPost] = []
  private(set) var replies: [AppBskyFeedDefs.FeedViewPost] = []
  private(set) var postsWithMedia: [AppBskyFeedDefs.FeedViewPost] = []
  private(set) var likes: [AppBskyFeedDefs.FeedViewPost] = []
  private(set) var lists: [AppBskyGraphDefs.ListView] = []

  // UI state
  private(set) var isLoading = false
  private(set) var isLoadingMorePosts = false
  private(set) var error: Error?
  var selectedProfileTab: ProfileTab = .posts

  // Pagination cursors
  private var postsCursor: String?
  private var repliesCursor: String?
  private var mediaPostsCursor: String?
  private var likesCursor: String?
  private var listsCursor: String?

  // Dependencies
  private let client: ATProtoClient?
  private let userDID: String  // This is the DID of the profile we're viewing
  private let currentUserDID: String? // This is the logged-in user's DID
  private let logger = Logger(subsystem: "blue.catbird", category: "ProfileViewModel")

  // Check if this is the current user's profile - comparing correctly
  var isCurrentUser: Bool {
    guard let profile = profile else { return false }
      return profile.did.didString() == currentUserDID
  }

  // MARK: - Initialization

  init(client: ATProtoClient?, userDID: String, currentUserDID: String?) {
    self.client = client
    self.userDID = userDID
    self.currentUserDID = currentUserDID
  }

  // MARK: - Public Methods

  /// Loads the user profile
  func loadProfile() async {
    guard let client = client else {
      self.error = NSError(
        domain: "ProfileViewModel", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Client not available"])
      return
    }

    isLoading = true
    error = nil

    do {
      let (responseCode, profileData) = try await client.app.bsky.actor.getProfile(
        input: .init(actor: try ATIdentifier(string: userDID))
      )

      await MainActor.run {
        if responseCode == 200, let profile = profileData {
          self.profile = profile
        } else {
          self.error = NSError(
            domain: "ProfileViewModel",
            code: responseCode,
            userInfo: [NSLocalizedDescriptionKey: "Failed to load profile: HTTP \(responseCode)"]
          )
        }
        self.isLoading = false
      }
    } catch {
      await MainActor.run {
        self.error = error
        self.isLoading = false
      }
    }
  }

  /// Loads user's posts
  func loadPosts() async {
    await loadFeed(type: .posts, resetCursor: postsCursor == nil)
  }

  /// Loads user's replies
  func loadReplies() async {
    await loadFeed(type: .replies, resetCursor: repliesCursor == nil)
  }

  /// Loads user's posts with media
  func loadMediaPosts() async {
    await loadFeed(type: .media, resetCursor: mediaPostsCursor == nil)
  }

  /// Loads user's liked posts
  func loadLikes() async {
    await loadFeed(type: .likes, resetCursor: likesCursor == nil)
  }

  /// Loads user's lists
  func loadLists() async {
    guard let client = client, let profile = profile, !isLoadingMorePosts else { return }

    isLoadingMorePosts = true

    do {
      let params = AppBskyGraphGetLists.Parameters(
        actor: try ATIdentifier(string: profile.did.didString()),
        limit: 20,
        cursor: listsCursor
      )

      let (responseCode, output) = try await client.app.bsky.graph.getLists(input: params)

      if responseCode == 200, let lists = output?.lists {
        await MainActor.run {
          if self.listsCursor == nil {
            self.lists = lists
          } else {
            self.lists.append(contentsOf: lists)
          }
          self.listsCursor = output?.cursor
          self.isLoadingMorePosts = false
        }
      } else {
        logger.warning("Failed to load lists: HTTP \(responseCode)")
        await MainActor.run { self.isLoadingMorePosts = false }
      }
    } catch {
      logger.error("Error loading lists: \(error.localizedDescription)")
      await MainActor.run { self.isLoadingMorePosts = false }
    }
  }

  // MARK: - Private Methods

  /// Load different types of feeds
  private func loadFeed(type: FeedType, resetCursor: Bool) async {
    guard let client = client, let profile = profile, !isLoadingMorePosts else { return }

    isLoadingMorePosts = true

    do {
      switch type {
      case .posts:
        let params = AppBskyFeedGetAuthorFeed.Parameters(
            actor: try ATIdentifier(string: profile.did.didString()),
          limit: 20,
          cursor: resetCursor ? nil : postsCursor,
          filter: "posts_no_replies"
        )

        let (responseCode, output) = try await client.app.bsky.feed.getAuthorFeed(input: params)

        if responseCode == 200, let feed = output?.feed {
          await MainActor.run {
            if resetCursor {
              self.posts = feed
            } else {
              self.posts.append(contentsOf: feed)
            }
            self.postsCursor = output?.cursor
          }
        }

      case .replies:
        let params = AppBskyFeedGetAuthorFeed.Parameters(
            actor: try ATIdentifier(string: profile.did.didString()),
          limit: 20,
          cursor: resetCursor ? nil : repliesCursor,
          filter: "posts_with_replies"
        )

        let (responseCode, output) = try await client.app.bsky.feed.getAuthorFeed(input: params)

        if responseCode == 200, let feed = output?.feed {
          // Filter to only include replies
          let repliesToOthers = feed.filter { post in
            // Check if post has a reply
            if let reply = post.reply {
              // Handle the parent union type without optional binding
              switch reply.parent {
              case .appBskyFeedDefsPostView(let parentPost):
                // If it's a reply to someone else's post
                return parentPost.author.did != profile.did
              case .appBskyFeedDefsNotFoundPost, .appBskyFeedDefsBlockedPost, .unexpected:
                // For other parent types, include them in the result
                return true
              }
            }
            return false
          }

          await MainActor.run {
            if resetCursor {
              self.replies = repliesToOthers
            } else {
              self.replies.append(contentsOf: repliesToOthers)
            }
            self.repliesCursor = output?.cursor
          }
        }

      case .media:
        let params = AppBskyFeedGetAuthorFeed.Parameters(
            actor: try ATIdentifier(string: profile.did.didString()),
          limit: 20,
          cursor: resetCursor ? nil : mediaPostsCursor
        )

        let (responseCode, output) = try await client.app.bsky.feed.getAuthorFeed(input: params)

        if responseCode == 200, let feed = output?.feed {
          // Filter to only include posts with media
          let postsWithMedia = feed.filter { post in
            if let embed = post.post.embed {
              switch embed {
              case .appBskyEmbedImagesView, .appBskyEmbedVideoView, .appBskyEmbedExternalView:
                return true
              case .appBskyEmbedRecordWithMediaView:
                return true
              default:
                return false
              }
            }
            return false
          }

          await MainActor.run {
            if resetCursor {
              self.postsWithMedia = postsWithMedia
            } else {
              self.postsWithMedia.append(contentsOf: postsWithMedia)
            }
            self.mediaPostsCursor = output?.cursor
          }
        }

      case .likes:
        let params = AppBskyFeedGetActorLikes.Parameters(
            actor: try ATIdentifier(string: profile.did.didString()),
          limit: 20,
          cursor: resetCursor ? nil : likesCursor
        )

        let (responseCode, output) = try await client.app.bsky.feed.getActorLikes(input: params)

        if responseCode == 200, let feed = output?.feed {
          await MainActor.run {
            if resetCursor {
              self.likes = feed
            } else {
              self.likes.append(contentsOf: feed)
            }
            self.likesCursor = output?.cursor
          }
        }
      }

      await MainActor.run {
        self.isLoadingMorePosts = false
      }

    } catch {
      logger.error(
        "Error loading feed (\(String(describing: type))): \(error.localizedDescription)")
      await MainActor.run {
        self.isLoadingMorePosts = false
      }
    }
  }

  // MARK: - Helper Types

  private enum FeedType {
    case posts, replies, media, likes
  }
    
    // MARK: Update Profile
    func updateProfile(displayName: String, description: String) async throws {
        guard let client = client else {
            throw NSError(domain: "ProfileCreation", code: 0, userInfo: [NSLocalizedDescriptionKey: "Client not available"])
        }
                
        guard let currentUserDID = currentUserDID else {
            throw NSError(domain: "ProfileCreation", code: 0, userInfo: [NSLocalizedDescriptionKey: "Current user DID not available"])
        }

        // Get the profile record
        let getRecordParams = ComAtprotoRepoGetRecord.Parameters(
            repo: try ATIdentifier(string: currentUserDID),
            collection: try NSID(nsidString:"app.bsky.actor.profile"),
            rkey: try RecordKey(keyString: "self")
        )
        let (getRecordCode, getRecordOutput) = try await client.com.atproto.repo.getRecord(input: getRecordParams)
        
        var updatedProfile: AppBskyActorProfile
        
        if getRecordCode == 200, let existingRecord = getRecordOutput {
            // Prepare the updated profile
            guard case let .knownType(value) = existingRecord.value,
                  let existingProfile = value as? AppBskyActorProfile else {
                throw NSError(domain: "ProfileDecoding", code: 0, userInfo: [NSLocalizedDescriptionKey: "Expected AppBskyActorProfile but found different type"])
            }
    
            updatedProfile = AppBskyActorProfile(
                displayName: displayName,
                description: description,
                avatar: existingProfile.avatar,
                banner: existingProfile.banner,
                labels: existingProfile.labels,
                joinedViaStarterPack: existingProfile.joinedViaStarterPack,
                pinnedPost: existingProfile.pinnedPost,
                createdAt: existingProfile.createdAt
            )
            
            // Put the updated record
            let putRecordInput = ComAtprotoRepoPutRecord.Input(
                repo: try ATIdentifier(string: currentUserDID),
                collection: try NSID(nsidString: "app.bsky.actor.profile"),
                rkey: try RecordKey(keyString: "self"),
                record: ATProtocolValueContainer.knownType(updatedProfile),
                swapRecord: existingRecord.cid  // Use the CID of the existing record for optimistic concurrency
            )
    
            let (putRecordCode, _) = try await client.com.atproto.repo.putRecord(input: putRecordInput)
            if putRecordCode == 200 {
                await loadProfile() // Refresh the profile
            } else {
                throw NSError(domain: "ProfileUpdate", code: putRecordCode, userInfo: [NSLocalizedDescriptionKey: "Error updating profile: Unexpected response code \(putRecordCode)"])
            }
        } else if getRecordCode == 400 {
            // Create a new profile record
            updatedProfile = AppBskyActorProfile(
                displayName: displayName,
                description: description,
                avatar: nil,
                banner: nil,
                labels: nil,
                joinedViaStarterPack: nil, pinnedPost: nil,
                createdAt: ATProtocolDate(date: Date())
            )
            

            
            let createRecordInput = ComAtprotoRepoCreateRecord.Input(
                repo: try ATIdentifier(string: currentUserDID),
                collection: try NSID(nsidString:"app.bsky.actor.profile"),
                rkey: try RecordKey(keyString:"self"),
                record: ATProtocolValueContainer.knownType(updatedProfile)
            )
            
            let (createRecordCode, _) = try await client.com.atproto.repo.createRecord(input: createRecordInput)
            if createRecordCode == 200 {
                await loadProfile() // Refresh the profile
            } else {
                throw NSError(domain: "ProfileCreation", code: createRecordCode, userInfo: [NSLocalizedDescriptionKey: "Error creating profile: Unexpected response code \(createRecordCode)"])
            }
        } else {
            throw NSError(domain: "ProfileUpdate", code: getRecordCode, userInfo: [NSLocalizedDescriptionKey: "Failed to get existing profile record"])
        }
    }

}

// MARK: - Supporting Types
enum ProfileTab: String, CaseIterable {
  case posts, replies, media, likes, lists
  
  var title: String {
    switch self {
    case .posts: return "Posts"
    case .replies: return "Replies"
    case .media: return "Media"
    case .likes: return "Likes"
    case .lists: return "Lists"
    }
  }
}
