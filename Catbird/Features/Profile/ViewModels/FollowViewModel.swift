//
//  FollowViewModel.swift
//  Catbird
//
//  Created by Josh LaCalamito on 4/3/25.
//

import Foundation
import Petrel
import Observation
import OSLog

@Observable final class FollowViewModel {
    private let client: ATProtoClient?
    private let userDID: String  // This is the DID of the profile we're viewing
    private let logger = Logger(subsystem: "blue.catbird", category: "FollowViewModel")

    private(set) var isLoadingMore = false
    private(set) var error: Error?

    private(set) var follows: [AppBskyActorDefs.ProfileView] = []
    private(set) var followers: [AppBskyActorDefs.ProfileView] = []

    private var followsCursor: String?
    private var followersCursor: String?

    private(set) var hasMoreFollows = false
    private(set) var hasMoreFollowers = false

    init(client: ATProtoClient?, userDID: String) {
      self.client = client
      self.userDID = userDID
    }
    
    /// Load user following
      func loadFollowing() async {
          guard let client = client, !isLoadingMore else { return }

          isLoadingMore = true
          error = nil

          do {
            let params = AppBskyGraphGetFollows.Parameters(
              actor: try ATIdentifier(string: userDID),
              limit: 20,
              cursor: followsCursor
            )

            let (responseCode, output) = try await client.app.bsky.graph.getFollows(input: params)

            if responseCode == 200, let follows = output?.follows {
              await MainActor.run {
                if self.follows.isEmpty {
                  self.follows = follows
                } else {
                  self.follows.append(contentsOf: follows)
                }
                self.followsCursor = output?.cursor
                self.hasMoreFollows = output?.cursor != nil
                self.isLoadingMore = false
              }
            } else {
              let errorMessage = "Failed to load following (HTTP \(responseCode))"
              logger.warning("Failed to load follows: HTTP \(responseCode)")
              await MainActor.run { 
                self.isLoadingMore = false 
                self.error = NSError(domain: "FollowError", code: responseCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
              }
            }
          } catch {
            logger.error("Error loading follows: \(error.localizedDescription)")
            await MainActor.run { 
              self.isLoadingMore = false 
              self.error = error
            }
          }
      }
      
      /// Load user followers
      func loadFollowers() async {
          guard let client = client, !isLoadingMore else { return }

          isLoadingMore = true
          error = nil

          do {
              let params = AppBskyGraphGetFollowers.Parameters(
                  actor: try ATIdentifier(string: userDID),
                  limit: 20,
                  cursor: followersCursor
              )

              let (responseCode, output) = try await client.app.bsky.graph.getFollowers(input: params)

              if responseCode == 200, let followers = output?.followers {
                  await MainActor.run {
                      self.isLoadingMore = false
                      // Handle followers data here
                      if self.followers.isEmpty {
                          self.followers = followers
                      } else {
                          self.followers.append(contentsOf: followers)
                      }
                      self.followersCursor = output?.cursor
                      self.hasMoreFollowers = output?.cursor != nil
                      self.isLoadingMore = false

                  }
              } else {
                  let errorMessage = "Failed to load followers (HTTP \(responseCode))"
                  logger.warning("Failed to load followers: HTTP \(responseCode)")
                  await MainActor.run { 
                    self.isLoadingMore = false 
                    self.error = NSError(domain: "FollowError", code: responseCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
                  }
              }
          } catch {
              logger.error("Error loading followers: \(error.localizedDescription)")
              await MainActor.run { 
                self.isLoadingMore = false 
                self.error = error
              }
          }
      }
      
      /// Clears the current error state
      func clearError() {
          error = nil
      }

}
