import Foundation
import OSLog
import SwiftUI

/// Service for reading and managing system logs from OSLog
@Observable
final class SystemLogService {
  
  // MARK: - Properties
  
  /// Array of log entries to display
  private(set) var logEntries: [LogEntry] = []
  
  /// Current filter settings
  private(set) var filterSettings = LogFilterSettings()
  
  /// Whether the service is currently loading logs
  private(set) var isLoading = false
  
  /// Maximum number of log entries to keep in memory
  private let maxLogEntries = 1000
  
  /// Log store for reading system logs
  private let logStore: OSLogStore
  
  /// Logger for this service
  private let logger = Logger(subsystem: OSLog.subsystem, category: "SystemLogService")
  
  // MARK: - Initialization
  
  init() throws {
    self.logStore = try OSLogStore(scope: .currentProcessIdentifier)
  }
  
  // MARK: - Public Methods
  
  /// Load recent log entries from the system
  func loadRecentLogs() async {
    await MainActor.run {
      isLoading = true
    }
    
    defer {
      Task { @MainActor in
        isLoading = false
      }
    }
    
    do {
      let entries = try await fetchLogEntries()
      await MainActor.run {
        self.logEntries = entries
      }
      logger.info("Loaded \(entries.count) log entries")
    } catch {
      logger.error("Failed to load logs: \(error)")
    }
  }
  
  /// Update filter settings and refresh logs
  func updateFilter(_ newSettings: LogFilterSettings) async {
    await MainActor.run {
      filterSettings = newSettings
    }
    await loadRecentLogs()
  }
  
  /// Clear all current log entries
  func clearLogs() {
    logEntries.removeAll()
    logger.info("Cleared all log entries")
  }
  
  /// Export logs as text
  func exportLogsAsText() -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    
    return logEntries.map { entry in
      let timestamp = formatter.string(from: entry.timestamp)
      let level = entry.level.displayName
      let category = entry.category
      let message = entry.message
      return "[\(timestamp)] [\(level)] [\(category)] \(message)"
    }.joined(separator: "\n")
  }
  
  // MARK: - Private Methods
  
  private func fetchLogEntries() async throws -> [LogEntry] {
    let predicate = buildLogPredicate()
    
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        guard let self = self else {
          continuation.resume(throwing: CancellationError())
          return
        }
        
        do {
          var entries: [LogEntry] = []
          
          let enumerator = try self.logStore.getEntries(
            with: [],
            at: self.logStore.position(timeIntervalSinceLatestBoot: 0),
            matching: predicate
          )
          
          for logEntry in enumerator.reversed() {
            if entries.count >= self.maxLogEntries { break }
            
            guard let logEntry = logEntry as? OSLogEntryLog else { continue }
            
            // Filter by subsystem if specified
            if !self.filterSettings.subsystems.isEmpty &&
               !self.filterSettings.subsystems.contains(logEntry.subsystem) {
              continue
            }
            
            // Filter by log level
            if !self.shouldIncludeLogLevel(logEntry.level) {
              continue
            }
            
            let entry = LogEntry(
              id: UUID(),
              timestamp: logEntry.date,
              level: LogLevel(from: logEntry.level),
              category: logEntry.category,
              subsystem: logEntry.subsystem,
              message: logEntry.composedMessage ?? "No message",
              process: logEntry.process,
              thread: logEntry.threadIdentifier
            )
            
            entries.append(entry)
          }
          
          continuation.resume(returning: entries.reversed())
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
  
  private func buildLogPredicate() -> NSPredicate {
    var predicates: [NSPredicate] = []
    
    // Time range filter
    let timeInterval = filterSettings.timeRange.timeInterval
    let startDate = Date().addingTimeInterval(-timeInterval)
    predicates.append(NSPredicate(format: "date >= %@", startDate as NSDate))
    
    // Subsystem filter
    if !filterSettings.subsystems.isEmpty {
      let subsystemPredicate = NSPredicate(format: "subsystem IN %@", filterSettings.subsystems)
      predicates.append(subsystemPredicate)
    }
    
    // Text search filter
    if !filterSettings.searchText.isEmpty {
      let searchPredicate = NSPredicate(format: "composedMessage CONTAINS[cd] %@", filterSettings.searchText)
      predicates.append(searchPredicate)
    }
    
    return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
  }
  
  private func shouldIncludeLogLevel(_ osLogType: OSLogEntryLog.Level) -> Bool {
    let logLevel = LogLevel(from: osLogType)
    return filterSettings.logLevels.contains(logLevel)
  }
}

// MARK: - Supporting Types

/// Represents a single log entry
struct LogEntry: Identifiable, Hashable {
  let id: UUID
  let timestamp: Date
  let level: LogLevel
  let category: String
  let subsystem: String
  let message: String
  let process: String
  let thread: UInt64
  
  /// Formatted timestamp for display
  var formattedTimestamp: String {
    let formatter = DateFormatter()
    formatter.timeStyle = .medium
    formatter.dateStyle = .none
    return formatter.string(from: timestamp)
  }
  
  /// Formatted full timestamp for details
  var fullTimestamp: String {
    let formatter = DateFormatter()
    formatter.timeStyle = .medium
    formatter.dateStyle = .short
    return formatter.string(from: timestamp)
  }
}

/// Log level enumeration
enum LogLevel: String, CaseIterable, Hashable {
  case debug = "debug"
  case info = "info"
  case notice = "notice"
  case error = "error"
  case fault = "fault"
  
  init(from osLogType: OSLogEntryLog.Level) {
    switch osLogType {
    case .debug:
      self = .debug
    case .info:
      self = .info
    case .notice:
      self = .notice
    case .error:
      self = .error
    case .fault:
      self = .fault
    @unknown default:
      self = .info
    }
  }
  
  var displayName: String {
    switch self {
    case .debug: return "Debug"
    case .info: return "Info"
    case .notice: return "Notice"
    case .error: return "Error"
    case .fault: return "Fault"
    }
  }
  
  var color: Color {
    switch self {
    case .debug: return .gray
    case .info: return .blue
    case .notice: return .green
    case .error: return .orange
    case .fault: return .red
    }
  }
  
  var systemImage: String {
    switch self {
    case .debug: return "ant.fill"
    case .info: return "info.circle.fill"
    case .notice: return "checkmark.circle.fill"
    case .error: return "exclamationmark.triangle.fill"
    case .fault: return "xmark.octagon.fill"
    }
  }
}

/// Time range options for log filtering
enum LogTimeRange: String, CaseIterable {
  case last5Minutes = "last5min"
  case last15Minutes = "last15min"
  case lastHour = "lasthour"
  case last6Hours = "last6hours"
  case last24Hours = "last24hours"
  
  var displayName: String {
    switch self {
    case .last5Minutes: return "Last 5 minutes"
    case .last15Minutes: return "Last 15 minutes"
    case .lastHour: return "Last hour"
    case .last6Hours: return "Last 6 hours"
    case .last24Hours: return "Last 24 hours"
    }
  }
  
  var timeInterval: TimeInterval {
    switch self {
    case .last5Minutes: return 5 * 60
    case .last15Minutes: return 15 * 60
    case .lastHour: return 60 * 60
    case .last6Hours: return 6 * 60 * 60
    case .last24Hours: return 24 * 60 * 60
    }
  }
}

/// Filter settings for log display
struct LogFilterSettings {
  var logLevels: Set<LogLevel> = Set(LogLevel.allCases)
  var subsystems: Set<String> = []
  var timeRange: LogTimeRange = .lastHour
  var searchText: String = ""
  
  /// Common Catbird subsystems for easy filtering
  static let catbirdSubsystems: [String] = [
    OSLog.subsystem,
    "com.apple.UIKit",
    "com.apple.SwiftUI"
  ]
}
