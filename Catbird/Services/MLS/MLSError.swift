//
//  MLSError.swift
//  Catbird
//
//  MLS-specific error types
//

import Foundation

/// Errors specific to MLS operations
public enum MLSError: LocalizedError {
    case conversationNotFound
    case noCurrentUser
    case operationFailed
    
    public var errorDescription: String? {
        switch self {
        case .conversationNotFound:
            return "Conversation not found"
        case .noCurrentUser:
            return "No current user authenticated"
        case .operationFailed:
            return "The operation failed."
        }
    }
}
