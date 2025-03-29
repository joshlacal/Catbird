//
//  NukeAVFoundationMonitor.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/2/25.
//

import Foundation
import os.log

/// A non-invasive monitor to help identify AVFoundation usage
enum DebugMonitor {
    private static let logger = Logger(subsystem: "blue.catbird", category: "DebugMonitor")
    
    /// Set up recommended debugging steps for diagnosing AVFoundation-related issues
    static func setupDebuggingRecommendations() {
        #if DEBUG
        // Instead of trying to instrument Nuke directly (which was causing compilation issues),
        // we recommend these debugging approaches:
        
        // 1. Set symbolic breakpoints in Xcode:
        // - Set a breakpoint on -[AVAsset preferredTransform]
        // - Set a breakpoint on UIImage imageWithCGImage:scale:orientation:
        // - Set a breakpoint on +[UIImage imageWithData:]
        
        // 2. Add Xcode breakpoint actions to log the call stack
        
        // 3. Use Instruments' Time Profiler to identify main thread blocking
        
//        logger.debug("""
//        📊 Debug recommendations:
//        1. Set symbolic breakpoint on -[AVAsset preferredTransform]
//        2. Set symbolic breakpoint on UIImage imageWithCGImage:scale:orientation:
//        3. Use Instruments' Time Profiler to identify main thread blocking
//        4. Check Console app for "Main thread blocked" messages
//        """)
        #endif
    }
}
