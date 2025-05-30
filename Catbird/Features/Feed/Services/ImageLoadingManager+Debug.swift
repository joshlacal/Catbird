//
//  ImageLoadingManager+Debug.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/2/25.
//

import Foundation
import Nuke
import UIKit
import os.log

// MARK: - Debug extensions for investigating image loading issues

extension ImageLoadingManager {
    private static let logger = Logger(subsystem: "blue.catbird", category: "ImageProcessing")
    
    /// Enable debug logging for image processing operations
    func enableDebugLogging() {
        #if DEBUG
        ImageLoadingManager.logger.debug("Debug logging enabled for image loading")
        
        // Monitor for any suspicious image processing that might involve video frames
        setupImageProcessingLogging()
        #endif
    }
    
    private func setupImageProcessingLogging() {
        // Monitor image operations that might be related to blocking issues
        ImageLoadingManager.logger.debug("Image processing monitoring enabled")
        
        // We can add breakpoints in AsyncImageDownscaling.process method
        // to detect when potentially problematic images are processed
    }
}

/// Extension to help identify when suspicious images are processed
extension UIImage {
    /// Check if an image has characteristics that might indicate it's a video frame
    /// or might trigger preferredTransform access
    var mightBeVideoFrame: Bool {
        // Video frames often have specific characteristics
        let hasNonStandardOrientation = imageOrientation != .up
        let hasCommonVideoSize = size.width.truncatingRemainder(dividingBy: 16) == 0 && 
                                 size.height.truncatingRemainder(dividingBy: 16) == 0
        
        return hasNonStandardOrientation && hasCommonVideoSize
    }
}

// MARK: - Image Processing Debug Helpers

/// Add a wrapper for debugging image processing
extension ImageProcessors.AsyncImageDownscaling {
    /// Log when processing suspicious images that might cause blocking issues
    func logIfSuspicious(_ image: UIImage) {
        #if DEBUG
        let logger = Logger(subsystem: "blue.catbird", category: "ImageProcessing")
        
        if image.mightBeVideoFrame {
            let threadType = Thread.isMainThread ? "⚠️ Main Thread" : "Background Thread"
            logger.warning("Processing potential video frame (\(image.size.width)x\(image.size.height)) on \(threadType)")
            
            if Thread.isMainThread {
                let callStack = Thread.callStackSymbols.prefix(8).joined(separator: "\n")
                logger.debug("Stack trace:\n\(callStack)")
            }
        }
        #endif
    }
}
