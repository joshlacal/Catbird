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
            
            logger.debug("Successfully got or created conversation with ID: \(convo.id)")
            
            // Return the conversation ID
            return convo.id
            
        } catch {
            logger.error("Error starting conversation: \(error.localizedDescription)")
            errorState = .generalError(error)
            return nil
        }
    }
}
