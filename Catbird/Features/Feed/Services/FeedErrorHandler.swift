//
//  FeedErrorHandler.swift
//  Catbird
//
//  Created by Claude on 7/13/25.
//

import Foundation
import OSLog

/// Standardized error handling patterns for feed operations
struct FeedErrorHandler {
    
    private static let logger = Logger(
        subsystem: "blue.catbird", 
        category: "FeedErrorHandler"
    )
    
    // MARK: - Error Classification
    
    /// Determines if an error should be shown to the user or handled silently
    static func shouldShowErrorToUser(_ error: Error) -> Bool {
        // Don't show cancellation errors - these are expected
        if isCancellationError(error) {
            return false
        }
        
        // Don't show network timeouts during background operations
        if isNetworkTimeoutError(error) {
            logger.debug("Network timeout (handled silently): \(error.localizedDescription)")
            return false
        }
        
        // Show other errors to user
        return true
    }
    
    /// Checks if error is a cancellation (expected during navigation/app state changes)
    static func isCancellationError(_ error: Error) -> Bool {
        // Check for NSURLErrorCancelled
        if (error as NSError).code == NSURLErrorCancelled {
            return true
        }
        
        // Check for Swift CancellationError
        if error is CancellationError {
            return true
        }
        
        // Check for cancellation in error description
        if error.localizedDescription.contains("cancelled") ||
           error.localizedDescription.contains("canceled") {
            return true
        }
        
        return false
    }
    
    /// Checks if error is a network timeout
    static func isNetworkTimeoutError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.code == NSURLErrorTimedOut ||
               nsError.code == NSURLErrorNetworkConnectionLost ||
               error.localizedDescription.contains("timeout")
    }
    
    /// Checks if error is recoverable and should trigger retry
    static func isRecoverableError(_ error: Error) -> Bool {
        // Cancellation errors are not recoverable
        if isCancellationError(error) {
            return false
        }
        
        // Network errors are potentially recoverable
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorCannotConnectToHost:
            return true
        default:
            break
        }
        
        // HTTP 5xx errors are potentially recoverable
        if nsError.domain == NSURLErrorDomain {
            return false
        }
        
        return false
    }
    
    // MARK: - Error Logging
    
    /// Logs error with appropriate level based on severity
    static func logError(_ error: Error, context: String, operation: String = "unknown") {
        if isCancellationError(error) {
            logger.debug("🟨 \(operation) cancelled (expected): \(error.localizedDescription) - Context: \(context)")
        } else if isNetworkTimeoutError(error) {
            logger.info("🟧 \(operation) timeout: \(error.localizedDescription) - Context: \(context)")
        } else {
            logger.error("🔴 \(operation) failed: \(error.localizedDescription) - Context: \(context)")
        }
    }
    
    /// Logs successful operations for debugging
    static func logSuccess(operation: String, details: String = "") {
        logger.debug("✅ \(operation) succeeded\(details.isEmpty ? "" : " - \(details)")")
    }
    
    // MARK: - Error Recovery
    
    /// Determines retry delay based on error type and attempt count
    static func retryDelay(for error: Error, attempt: Int) -> TimeInterval {
        // Don't retry cancellation errors
        if isCancellationError(error) {
            return 0
        }
        
        // Exponential backoff for network errors
        if isNetworkTimeoutError(error) {
            return min(pow(2.0, Double(attempt)) * FeedConstants.retryDelay, 30.0)
        }
        
        // Fixed delay for other errors
        return FeedConstants.retryDelay
    }
    
    /// Creates user-friendly error message
    static func userFriendlyMessage(for error: Error, context: String) -> String {
        if isNetworkTimeoutError(error) {
            return "Network connection issue. Please check your connection and try again."
        }
        
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet:
            return "No internet connection. Please connect to the internet and try again."
        case NSURLErrorCannotConnectToHost:
            return "Unable to connect to server. Please try again later."
        default:
            return "Something went wrong. Please try again."
        }
    }
}

// MARK: - Convenience Extensions

extension Error {
    
    /// Returns true if this error should be shown to the user
    var shouldShowToUser: Bool {
        FeedErrorHandler.shouldShowErrorToUser(self)
    }
    
    /// Returns true if this is a cancellation error
    var isCancellation: Bool {
        FeedErrorHandler.isCancellationError(self)
    }
    
    /// Returns true if this error is recoverable
    var isRecoverable: Bool {
        FeedErrorHandler.isRecoverableError(self)
    }
    
    /// Returns user-friendly error message
    func userFriendlyMessage(context: String = "") -> String {
        FeedErrorHandler.userFriendlyMessage(for: self, context: context)
    }
    
    /// Logs this error with appropriate level
    func logError(context: String, operation: String = "unknown") {
        FeedErrorHandler.logError(self, context: context, operation: operation)
    }
}