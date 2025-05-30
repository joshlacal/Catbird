import Foundation

class FeedConfiguration {
    static let shared = FeedConfiguration()
    
    let imagePrefetchLimit = 10  // Maximum number of images to prefetch ahead
    let postPrefetchCount = 3    // Number of posts to prefetch ahead when scrolling
    
    private init() {}
}
