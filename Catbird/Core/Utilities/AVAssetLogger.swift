//
//  AVAssetLogger.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/2/25.
//

import AVFoundation
import Foundation
import os.log

/// A simplified logger for tracking AVAsset property access
struct AVAssetPropertyTracker {
    private static let logger = Logger(subsystem: "blue.catbird", category: "AVAssetAccess")
    
    /// Track access to PreferredTransform property, which has been causing blocking issues
    static func logPreferredTransformAccess(file: String = #file, line: Int = #line, function: String = #function) {
        let sourceFileName = (file as NSString).lastPathComponent
        let isMainThread = Thread.isMainThread
        let threadLabel = isMainThread ? "Main Thread ⚠️" : "Background Thread"
        
        logger.debug("PreferredTransform accessed on \(threadLabel) from \(sourceFileName):\(line) - \(function)")
        
        if isMainThread {
            let callStack = Thread.callStackSymbols.prefix(10).joined(separator: "\n")
            logger.warning("⚠️ PreferredTransform accessed on Main Thread! Stack trace:\n\(callStack)")
        }
    }
    
    /// Set up breakpoint to track preferredTransform access
    static func setupBreakpointTracking() {
        #if DEBUG
        // Instead of swizzling, we recommend:
        // 1. Set a symbolic breakpoint in Xcode on -[AVAsset preferredTransform]
        // 2. Add a breakpoint action to log the stack trace
        // 3. Allow the breakpoint to continue
        
        logger.debug("Set a symbolic breakpoint on -[AVAsset preferredTransform] to track access points")
        #endif
    }
}
