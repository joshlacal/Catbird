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
            return (
                .unauthorized,
                String(localized: "Your session has expired. Please sign in again.", comment: "Authentication error message when the user's session has expired."),
                true
            )
        }
        
        // Check for token refresh failures
        if errorDescription.contains("token") && (errorDescription.contains("refresh") || errorDescription.contains("invalid")) {
            return (
                .tokenRefreshFailed,
                String(localized: "Your session has expired. Please sign in again.", comment: "Authentication error message when token refresh fails."),
                true
            )
        }
        
        // Check for invalid credentials
        if errorDescription.contains("invalid") && (errorDescription.contains("credential") || errorDescription.contains("password") || errorDescription.contains("username")) {
            return (
                .invalidCredentials,
                String(localized: "Invalid credentials. Please check your login information and try again.", comment: "Authentication error message for incorrect login credentials."),
                true
            )
        }
        
        // Check for network errors
        if errorDescription.contains("network") || errorDescription.contains("connection") || errorDescription.contains("internet") {
            return (
                .networkError,
                String(localized: "Network connection issue. Please check your internet connection and try again.", comment: "Authentication error message when offline."),
                false
            )
        }
        
        // Check for server errors (5xx)
        if errorCode >= 500 && errorCode < 600 {
            return (
                .serverError,
                String(localized: "Server is temporarily unavailable. Please try again later.", comment: "Authentication error message for 5xx server errors."),
                false
            )
        }
        
        // Check for session expired patterns
        if errorDescription.contains("session") && (errorDescription.contains("expired") || errorDescription.contains("invalid")) {
            return (
                .sessionExpired,
                String(localized: "Your session has expired. Please sign in again.", comment: "Authentication error message when the session is invalid."),
                true
            )
        }
        
        // Check for authentication patterns
        if errorDescription.contains("authentication") || errorDescription.contains("auth") {
            return (
                .sessionExpired,
                String(localized: "Authentication required. Please sign in again.", comment: "Authentication error message prompting the user to sign in."),
                true
            )
        }
        
        // Default case
        return (
            .unknown,
            String(localized: "An unexpected error occurred. Please try again.", comment: "Generic fallback authentication error message."),
            false
        )
    }
    
    /// Gets a user-friendly title for the error type
    static func titleForErrorType(_ type: AuthErrorType) -> String {
        switch type {
        case .sessionExpired, .unauthorized, .tokenRefreshFailed:
            return String(localized: "Session Expired", comment: "Alert title when user session has expired.")
        case .invalidCredentials:
            return String(localized: "Invalid Credentials", comment: "Alert title when login credentials are invalid.")
        case .networkError:
            return String(localized: "Connection Error", comment: "Alert title for a network connection failure.")
        case .serverError:
            return String(localized: "Server Error", comment: "Alert title when the server returns an error.")
        case .unknown:
            return String(localized: "Error", comment: "Generic alert title for an unexpected error.")
        }
    }
    
    /// Gets an appropriate action button title for the error type
    static func actionButtonTitle(_ type: AuthErrorType) -> String {
        switch type {
        case .sessionExpired, .unauthorized, .tokenRefreshFailed, .invalidCredentials:
            return String(localized: "Sign In Again", comment: "Button title prompting user to sign in again.")
        case .networkError:
            return String(localized: "Retry", comment: "Button title to retry a failed network request.")
        case .serverError:
            return String(localized: "Try Again Later", comment: "Button title dismissing a temporary server error.")
        case .unknown:
            return String(localized: "Retry", comment: "Button title to retry after an unexpected error.")
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