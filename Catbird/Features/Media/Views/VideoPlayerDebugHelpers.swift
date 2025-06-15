import os.log

extension ModernVideoPlayerView18 {
    // Add this debug helper
    private func logLifecycle(_ event: String) {
        logger.debug("[VideoPlayer-\(postID.suffix(8))] \(event)")
    }
    
    // Use in key places:
    // - init: logLifecycle("init")
    // - body: logLifecycle("body called")
    // - setupPlayer: logLifecycle("setupPlayer started")
    // - cleanupPlayer: logLifecycle("cleanupPlayer")
    // - deinit (if we add one): logLifecycle("deinit")
}
