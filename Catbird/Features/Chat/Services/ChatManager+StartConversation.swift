import Foundation
import OSLog
import Petrel
import SwiftUI

extension ChatManager {
    /// Checks if you can start a conversation with a user and returns existing conversation if available
    @MainActor
    func checkAndStartConversation(userDID: String) async -> (canChat: Bool, convoId: String?) {
        guard let client = client else {
            logger.error("Cannot check conversation: client is nil")
            errorState = .noClient
            return (false, nil)
        }
        
        guard let currentUserDID = try? await client.getDid() else {
            logger.error("Cannot check conversation: failed to get current user DID")
            return (false, nil)
        }
        
        // First check availability
        let (canChat, existingConvo) = await checkConversationAvailability(members: [currentUserDID, userDID])
        
        if canChat {
            if let existing = existingConvo {
                // Return existing conversation
                return (true, existing.id)
            } else {
                // Can chat but no existing conversation, create new one
                let convoId = await startConversationWith(userDID: userDID)
                return (convoId != nil, convoId)
            }
        }
        
        return (false, nil)
    }
    
    /// Starts a conversation with a user identified by their DID
    /// Returns the conversation ID if successful
    @MainActor
    func startConversationWith(userDID: String) async -> String? {
        guard let client = client else {
            logger.error("Cannot start conversation: client is nil")
            errorState = .noClient
            return nil
        }
        
        // Ensure we have the current user's DID
        guard let currentUserDID = try? await client.getDid() else {
            logger.error("Cannot start conversation: failed to get current user DID")
            errorState = .generalError(NSError(domain: "ChatManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to get current user DID"]))
            return nil
        }
        
        // Create DIDs array with both users
        do {
            let userDID = try DID(didString: userDID)
            let currentDID = try DID(didString: currentUserDID)
            
            let members = [currentDID, userDID]
            let params = ChatBskyConvoGetConvoForMembers.Parameters(members: members)
            
            logger.debug("Getting or creating conversation with user: \(userDID.didString())")
                     
            let (responseCode, response) = try await client.chat.bsky.convo.getConvoForMembers(input: params)
                   
            guard responseCode >= 200 && responseCode < 300 else {
                logger.error("Error getting conversation: HTTP \(responseCode)")
                errorState = .networkError(code: responseCode)
                return nil
            }
            
            guard let convoData = response else {
                logger.error("No data returned from conversation request")
                errorState = .emptyResponse
                return nil
            }
            
            // Add or update the conversation in our local state
            let convo = convoData.convo
            
            // Check if the conversation already exists locally
            if let existingIndex = conversations.firstIndex(where: { $0.id == convo.id }) {
                conversations[existingIndex] = convo
            } else {
                // Add to the beginning of the list
                conversations.insert(convo, at: 0)
            }
            updateConversationsByStatus()
            onUnreadCountChanged?()
            
            logger.debug("Successfully got or created conversation with ID: \(convo.id)")
            
            // Return the conversation ID
            return convo.id
            
        } catch {
            logger.error("Error starting conversation: \(error.localizedDescription)")
            errorState = .generalError(error)
            return nil
        }
    }

    /// Creates a native Bluesky group conversation using the unencrypted chat.bsky group APIs.
    /// Returns the conversation ID if successful.
    @MainActor
    func startGroupConversation(memberDIDs: [String], name: String) async -> String? {
        guard let client = client else {
            logger.error("Cannot start group conversation: client is nil")
            errorState = .noClient
            return nil
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            logger.error("Cannot start group conversation: missing group name")
            errorState = .generalError(NSError(domain: "ChatManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "Group name is required"]))
            return nil
        }

        guard let currentUserDID = try? await client.getDid() else {
            logger.error("Cannot start group conversation: failed to get current user DID")
            errorState = .generalError(NSError(domain: "ChatManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "Failed to get current user DID"]))
            return nil
        }

        var seenMemberDIDs = Set<String>()
        let uniqueMemberDIDs = memberDIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { did in
                guard !did.isEmpty, did != currentUserDID, !seenMemberDIDs.contains(did) else {
                    return false
                }
                seenMemberDIDs.insert(did)
                return true
            }

        guard !uniqueMemberDIDs.isEmpty else {
            logger.error("Cannot start group conversation: no members selected")
            errorState = .generalError(NSError(domain: "ChatManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "Select at least one person"]))
            return nil
        }

        do {
            let members = try uniqueMemberDIDs.map { try DID(didString: $0) }
            let input = ChatBskyGroupCreateGroup.Input(members: members, name: trimmedName)

            logger.debug("Creating Bluesky group conversation named: \(trimmedName, privacy: .private)")

            let (responseCode, response) = try await client.chat.bsky.group.createGroup(input: input)

            guard responseCode >= 200 && responseCode < 300 else {
                logger.error("Error creating group conversation: HTTP \(responseCode)")
                errorState = .networkError(code: responseCode)
                return nil
            }

            guard let convoData = response else {
                logger.error("No data returned from group conversation request")
                errorState = .emptyResponse
                return nil
            }

            let convo = convoData.convo

            if let existingIndex = conversations.firstIndex(where: { $0.id == convo.id }) {
                conversations[existingIndex] = convo
            } else {
                conversations.insert(convo, at: 0)
            }

            updateConversationsByStatus()
            onUnreadCountChanged?()

            logger.debug("Successfully created group conversation with ID: \(convo.id)")
            return convo.id
        } catch {
            logger.error("Error creating group conversation: \(error.localizedDescription)")
            errorState = .generalError(error)
            return nil
        }
    }
}
