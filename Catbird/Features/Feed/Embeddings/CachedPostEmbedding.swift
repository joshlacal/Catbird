import Foundation
import SwiftData

/// Disk sidecar cache for on-device embedding vectors
@Model
final class CachedPostEmbedding {
    @Attribute(.unique) var postID: String
    var languageCode: String
    var vectorData: Data
    var timestamp: Date

    init(postID: String, languageCode: String, vectorData: Data, timestamp: Date = Date()) {
        self.postID = postID
        self.languageCode = languageCode
        self.vectorData = vectorData
        self.timestamp = timestamp
    }
}

