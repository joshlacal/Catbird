import Foundation
import OSLog

/// Swift implementation of MLSLogger that bridges Rust FFI logs to OSLog
///
/// Usage:
/// ```swift
/// let context = MlsContext()
/// let logger = MLSLoggerImplementation()
/// context.setLogger(logger: logger)
/// ```
class MLSLoggerImplementation: MLSLogger {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.catbird",
        category: "MLSFFI"
    )

    /// Receive log messages from Rust FFI and forward to OSLog
    func log(level: String, message: String) {
        switch level.lowercased() {
        case "debug":
            logger.debug("\(message, privacy: .public)")
        case "info":
            logger.info("\(message, privacy: .public)")
        case "warning":
            logger.warning("\(message, privacy: .public)")
        case "error":
            logger.error("\(message, privacy: .public)")
        default:
            logger.log("\(message, privacy: .public)")
        }
    }
}

// MARK: - Integration Instructions
/*

 To integrate MLS FFI logging into your app:

 1. Import the generated MLSFFI module:
    import MLSFFI

 2. Create logger instance and set it on MLSContext during app initialization:

    // In CatbirdApp.swift or similar initialization point
    let mlsContext = MLSClient.shared.context
    let logger = MLSLoggerImplementation()
    mlsContext.setLogger(logger: logger)

 3. All Rust FFI logs will now appear in Console.app filtered by:
    - Subsystem: com.catbird (or your bundle ID)
    - Category: MLSFFI

 4. View logs in Console.app:
    - Open Console.app
    - Filter by "process:Catbird subsystem:com.catbird category:MLSFFI"
    - Or use: log stream --predicate 'subsystem == "com.catbird" AND category == "MLSFFI"'

 */
