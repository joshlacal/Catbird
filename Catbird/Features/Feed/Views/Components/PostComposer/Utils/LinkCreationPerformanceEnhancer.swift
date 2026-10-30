//
//  LinkCreationPerformanceEnhancer.swift
//  Catbird
//
//  Shared animations for creating and editing inline links in the composer
//

import SwiftUI

@available(iOS 16.0, macOS 13.0, *)
enum LinkCreationPerformanceEnhancer {
    /// Optimized animation configuration for link creation
    static let linkCreationAnimation = SwiftUI.Animation.interactiveSpring(
        response: 0.3,
        dampingFraction: 0.8,
        blendDuration: 0.1
    )

    static let linkEditingAnimation = SwiftUI.Animation.easeInOut(duration: 0.2)
}
