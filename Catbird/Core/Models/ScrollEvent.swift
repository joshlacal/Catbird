import Foundation

/// Represents a scroll-related event for debugging purposes
public struct CatbirdScrollEvent: Identifiable {
  public let id = UUID()
  public let timestamp: Date
  public let title: String
  public let description: String
  public let type: EventType

  public enum EventType {
    case success
    case error
    case contentShift
    case warning
    case info
  }

  public var formattedTimestamp: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: timestamp)
  }

  public init(timestamp: Date, title: String, description: String, type: EventType) {
    self.timestamp = timestamp
    self.title = title
    self.description = description
    self.type = type
  }
}
