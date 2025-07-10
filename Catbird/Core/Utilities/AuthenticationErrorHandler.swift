//
//  AuthenticationErrorHandler.swift
//  Catbird
//
//  Created by Claude on 6/18/25.
//

import Foundation

/// Utility for handling authentication errors with user-friendly messages
struct AuthenticationErrorHandler {
    
    /// Represents different types of authentication errors
    enum AuthErrorType {
        case sessionExpired
        case invalidCredentials
        case networkError
        case serverError
        case tokenRefreshFailed
        case unauthorized
        case unknown
    }
    
    /// Categorizes an error and returns a user-friendly message
    static func categorizeError(_ error: Error) -> (type: AuthErrorType, message: String, shouldReAuthenticate: Bool) {
        let errorDescription = error.localizedDescription.lowercased()
        let errorCode = (error as NSError).code
        
        // Check for 401 unauthorized errors
        if errorCode == 401 || errorDescription.contains("401") || errorDescription.contains("unauthorized") {
            return (.unauthorized, "Your session has expired. Please sign in again.", true)
        }
        
        // Check for token refresh failures
        if errorDescription.contains("token") && (errorDescription.contains("refresh") || errorDescription.contains("invalid")) {
            return (.tokenRefreshFailed, "Your session has expired. Please sign in again.", true)
        }
        
        // Check for invalid credentials
        if errorDescription.contains("invalid") && (errorDescription.contains("credential") || errorDescription.contains("password") || errorDescription.contains("username")) {
            return (.invalidCredentials, "Invalid credentials. Please check your login information and try again.", true)
        }
        
        // Check for network errors
        if errorDescription.contains("network") || errorDescription.contains("connection") || errorDescription.contains("internet") {
            return (.networkError, "Network connection issue. Please check your internet connection and try again.", false)
        }
        
        // Check for server errors (5xx)
        if errorCode >= 500 && errorCode < 600 {
            return (.serverError, "Server is temporarily unavailable. Please try again later.", false)
        }
        
        // Check for session expired patterns
        if errorDescription.contains("session") && (errorDescription.contains("expired") || errorDescription.contains("invalid")) {
            return (.sessionExpired, "Your session has expired. Please sign in again.", true)
        }
        
        // Check for authentication patterns
        if errorDescription.contains("authentication") || errorDescription.contains("auth") {
            return (.sessionExpired, "Authentication required. Please sign in again.", true)
        }
        
        // Default case
        return (.unknown, "An unexpected error occurred. Please try again.", false)
    }
    
    /// Gets a user-friendly title for the error type
    static func titleForErrorType(_ type: AuthErrorType) -> String {
        switch type {
        case .sessionExpired, .unauthorized, .tokenRefreshFailed:
            return "Session Expired"
        case .invalidCredentials:
            return "Invalid Credentials"
        case .networkError:
            return "Connection Error"
        case .serverError:
            return "Server Error"
        case .unknown:
            return "Error"
        }
    }
    
    /// Gets an appropriate action button title for the error type
    static func actionButtonTitle(_ type: AuthErrorType) -> String {
        switch type {
        case .sessionExpired, .unauthorized, .tokenRefreshFailed, .invalidCredentials:
            return "Sign In Again"
        case .networkError:
            return "Retry"
        case .serverError:
            return "Try Again Later"
        case .unknown:
            return "Retry"
        }
    }
    
    /// Checks if an error requires re-authentication
    static func requiresReAuthentication(_ error: Error) -> Bool {
        let (_, _, shouldReAuth) = categorizeError(error)
        return shouldReAuth
    }
    
    /// Gets a concise user-friendly message for an error
    static func userFriendlyMessage(for error: Error) -> String {
        let (_, message, _) = categorizeError(error)
        return message
    }
}