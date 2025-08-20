//
//  iOS18StateRestorationCoordinator.swift  
//  Catbird
//
//  iOS 18+ Enhanced State Restoration Coordinator
//  Unifies SwiftUI @Observable pattern with UIKit state restoration
//

import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import os

/// Coordinates state restoration between SwiftUI @Observable and UIKit components in iOS 18+
@available(iOS 18.0, *)
@MainActor @Observable
final class iOS18StateRestorationCoordinator {
    static let shared = iOS18StateRestorationCoordinator()
    
    // MARK: - Properties
    
    /// Active UIKit controllers that need restoration coordination
    private var activeControllers: [String: WeakControllerReference] = [:]
    
    /// Scene phase state for coordination
    private var currentScenePhase: ScenePhase = .active
    
    /// Restoration state tracking
    private var isRestorationInProgress = false
    private var lastRestorationTime: Date = .distantPast
    
    private let logger = Logger(subsystem: "blue.catbird", category: "iOS18StateRestoration")
    
    private init() {}
    
    // MARK: - Controller Registration
    
    /// Register a UIKit controller for state restoration coordination
    func registerController(_ controller: FeedCollectionViewControllerIntegrated, identifier: String) {
        activeControllers[identifier] = WeakControllerReference(controller: controller)
        logger.debug("📝 Registered controller for restoration: \(identifier)")
    }
    
    /// Unregister a UIKit controller
    func unregisterController(identifier: String) {
        activeControllers.removeValue(forKey: identifier)
        logger.debug("❌ Unregistered controller: \(identifier)")
    }
    
    // MARK: - Scene Phase Coordination
    
    /// Handle scene phase change with coordinated restoration
    func handleScenePhaseChange(
        _ newPhase: ScenePhase,
        backgroundDuration: TimeInterval = 0
    ) async {
        let oldPhase = currentScenePhase
        currentScenePhase = newPhase
        
        logger.debug("🎭 Scene phase coordination: \(String(describing: oldPhase)) -> \(String(describing: newPhase))")
        
        switch newPhase {
        case .active:
            await handleActivePhase(from: oldPhase, backgroundDuration: backgroundDuration)
        case .inactive:
            await handleInactivePhase()
        case .background:
            await handleBackgroundPhase()
        @unknown default:
            logger.debug("⚠️ Unknown scene phase: \(String(describing: newPhase))")
        }
    }
    
    // MARK: - Phase Handlers
    
    private func handleActivePhase(from oldPhase: ScenePhase, backgroundDuration: TimeInterval) async {
        logger.debug("✅ Handling active phase from \(String(describing: oldPhase)), background duration: \(backgroundDuration)s")
        
        // Only perform restoration if coming from background and duration is short enough to warrant preservation
        guard oldPhase == .background && backgroundDuration < 600 else { // 10 minutes
            logger.debug("⏭️ Skipping restoration - not from background or too long duration")
            return
        }
        
        // Coordinate restoration with active controllers
        await performCoordinatedRestoration()
    }
    
    private func handleInactivePhase() async {
        logger.debug("⏸️ Handling inactive phase - preparing controllers")
        
        // Notify controllers to prepare for potential backgrounding
        for (identifier, controllerRef) in activeControllers {
            if let controller = controllerRef.controller {
                // Controllers should save state proactively
                controller.savePersistedScrollState()
                logger.debug("💾 Prepared controller for backgrounding: \(identifier)")
            }
        }
    }
    
    private func handleBackgroundPhase() async {
        logger.debug("🌙 Handling background phase - saving all states")
        
        // Final state save for all controllers
        for (identifier, controllerRef) in activeControllers {
            if let controller = controllerRef.controller {
                controller.savePersistedScrollState(force: true)
                logger.debug("💾 Saved final state for controller: \(identifier)")
            }
        }
    }
    
    // MARK: - Coordinated Restoration
    
    private func performCoordinatedRestoration() async {
        guard !isRestorationInProgress else {
            logger.debug("🔄 Restoration already in progress - skipping")
            return
        }
        
        // Prevent multiple simultaneous restoration attempts
        let timeSinceLastRestoration = Date().timeIntervalSince(lastRestorationTime)
        guard timeSinceLastRestoration > 1.0 else {
            logger.debug("🔄 Restoration attempted too recently - skipping")
            return
        }
        
        isRestorationInProgress = true
        lastRestorationTime = Date()
        
        logger.debug("🔄 Starting coordinated restoration for \(self.activeControllers.count) controllers")
        
        // Restore each controller in sequence to avoid conflicts
        for (identifier, controllerRef) in activeControllers {
            guard let controller = controllerRef.controller else {
                logger.debug("⚠️ Controller reference is nil: \(identifier)")
                continue
            }
            
            logger.debug("🔄 Restoring controller: \(identifier)")
            await controller.handleScenePhaseRestoration()
        }
        
        isRestorationInProgress = false
        logger.debug("✅ Coordinated restoration completed")
    }
    
    // MARK: - Cleanup
    
    /// Clean up weak references
    func cleanup() {
        // Remove nil references
        activeControllers = activeControllers.compactMapValues { ref in
            ref.controller != nil ? ref : nil
        }
        
        logger.debug("🧹 Cleanup completed - active controllers: \(self.activeControllers.count)")
    }
}

// MARK: - Supporting Types

/// Weak reference wrapper for UIKit controllers
private class WeakControllerReference {
    weak var controller: FeedCollectionViewControllerIntegrated?
    
    init(controller: FeedCollectionViewControllerIntegrated) {
        self.controller = controller
    }
}

// MARK: - SwiftUI Integration

/// SwiftUI view modifier for iOS 18+ state restoration coordination
@available(iOS 18.0, *)
struct iOS18StateRestorationModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    
    let coordinatedRestoration: Bool
    
    @State private var lastScenePhase: ScenePhase = .active
    @State private var backgroundTime: Date = .distantPast
    
    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { oldPhase, newPhase in
                // Track background duration for intelligent restoration
                if newPhase == .background {
                    backgroundTime = Date()
                }
                
                let backgroundDuration: TimeInterval = {
                    if oldPhase == .background {
                        return Date().timeIntervalSince(backgroundTime)
                    }
                    return 0
                }()
                
                if coordinatedRestoration {
                    Task {
                        await iOS18StateRestorationCoordinator.shared.handleScenePhaseChange(
                            newPhase,
                            backgroundDuration: backgroundDuration
                        )
                    }
                }
                
                lastScenePhase = newPhase
            }
    }
}

@available(iOS 18.0, *)
extension View {
    /// Enable iOS 18+ coordinated state restoration
    func coordinatedStateRestoration(enabled: Bool = true) -> some View {
        modifier(iOS18StateRestorationModifier(coordinatedRestoration: enabled))
    }
}

// MARK: - Feed-Specific Support

/// Feed-specific iOS 18+ state restoration support
struct iOS18StateRestorationSupport: ViewModifier {
    let feedType: FetchType
    
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .coordinatedStateRestoration(enabled: true)
        } else {
            content
        }
    }
}
