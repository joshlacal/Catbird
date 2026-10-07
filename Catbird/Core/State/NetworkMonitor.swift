import Network
import Foundation
import Observation
import OSLog

@MainActor @Observable
final class NetworkMonitor {
  static let shared = NetworkMonitor()

  private(set) var isConnected = true
  private(set) var connectionType: ConnectionType = .unknown
  /// Advances only after an observed unavailable path becomes available again.
  private(set) var restorationGeneration: UInt64 = 0

  @ObservationIgnored private var hasReceivedPath = false
  @ObservationIgnored private let monitor: NWPathMonitor?
  @ObservationIgnored private let queue = DispatchQueue(label: "NetworkMonitor")
  @ObservationIgnored private let logger = Logger(subsystem: "blue.catbird", category: "NetworkMonitor")

  enum ConnectionType: Sendable {
    case wifi
    case cellular
    case ethernet
    case unknown
    case none

    var displayName: String {
      switch self {
      case .wifi: return "Wi-Fi"
      case .cellular: return "Cellular"
      case .ethernet: return "Ethernet"
      case .unknown: return "Unknown"
      case .none: return "No Connection"
      }
    }

    var isConnected: Bool { self != .none }
  }

  struct Snapshot: Sendable {
    let isConnected: Bool
    let connectionType: ConnectionType
  }

  /// Tests can apply snapshots without starting a system path monitor.
  init(startMonitoring: Bool = true) {
    monitor = startMonitoring ? NWPathMonitor() : nil
    monitor?.pathUpdateHandler = { [weak self] path in
      let snapshot = Self.snapshot(for: path)
      Task { @MainActor [weak self] in
        self?.apply(snapshot)
      }
    }
    monitor?.start(queue: queue)
  }

  isolated deinit {
    monitor?.cancel()
  }

  nonisolated private static func snapshot(for path: NWPath) -> Snapshot {
    let isConnected = path.status == .satisfied
    let connectionType: ConnectionType
    if !isConnected {
      connectionType = .none
    } else if path.usesInterfaceType(.wifi) {
      connectionType = .wifi
    } else if path.usesInterfaceType(.cellular) {
      connectionType = .cellular
    } else if path.usesInterfaceType(.wiredEthernet) {
      connectionType = .ethernet
    } else {
      connectionType = .unknown
    }
    return Snapshot(isConnected: isConnected, connectionType: connectionType)
  }

  func apply(_ snapshot: Snapshot) {
    let wasConnected = isConnected
    let restored = hasReceivedPath && !wasConnected && snapshot.isConnected
    hasReceivedPath = true
    isConnected = snapshot.isConnected
    connectionType = snapshot.isConnected ? snapshot.connectionType : .none
    if restored {
      restorationGeneration &+= 1
      logger.info("Network connection restored: \(self.connectionType.displayName)")
    } else if wasConnected && !isConnected {
      logger.warning("Network connection lost")
    }
  }
}
