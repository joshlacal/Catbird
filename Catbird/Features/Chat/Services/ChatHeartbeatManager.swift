#if os(iOS)
import Foundation
import OSLog
import Petrel

/// Sends a heartbeat POST to Nest every 60 seconds while any chat view is visible.
///
/// Uses reference counting so multiple chat views (e.g., conversation list + detail)
/// can be active simultaneously without spawning duplicate heartbeat loops.
@Observable
final class ChatHeartbeatManager {
  private let logger = Logger(subsystem: "blue.catbird", category: "ChatHeartbeat")

  /// Service DID for routing heartbeat calls through Nest.
  private static let nestServiceDID = "did:web:api.catbird.blue"

  /// XRPC endpoint for push heartbeat.
  private static let heartbeatEndpoint = "blue.catbird.bskychat.pushHeartbeat"

  /// Heartbeat interval in seconds.
  private static let heartbeatInterval: TimeInterval = 60

  // MARK: - State

  /// Number of chat views currently visible.
  @ObservationIgnored private var activeViewCount = 0

  /// The running heartbeat loop task.
  @ObservationIgnored private var heartbeatTask: Task<Void, Never>?

  /// ATProtoClient for making XRPC calls.
  private weak var _client: ATProtoClient?

  var client: ATProtoClient? {
    get { _client }
    set { _client = newValue }
  }

  // MARK: - Public API

  /// Called when a chat view appears. Starts heartbeat if this is the first active view.
  func viewAppeared() {
    activeViewCount += 1
    logger.debug("Chat view appeared (active count: \(self.activeViewCount))")

    if activeViewCount == 1 {
      startHeartbeat()
    }
  }

  /// Called when a chat view disappears. Stops heartbeat when all views have disappeared.
  func viewDisappeared() {
    activeViewCount = max(0, activeViewCount - 1)
    logger.debug("Chat view disappeared (active count: \(self.activeViewCount))")

    if activeViewCount == 0 {
      stopHeartbeat()
    }
  }

  // MARK: - Heartbeat Loop

  private func startHeartbeat() {
    guard heartbeatTask == nil else { return }
    logger.info("Starting chat heartbeat loop")

    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.sendHeartbeat()
        do {
          try await Task.sleep(for: .seconds(Self.heartbeatInterval))
        } catch {
          break
        }
      }
    }
  }

  private func stopHeartbeat() {
    logger.info("Stopping chat heartbeat loop")
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }

  private func sendHeartbeat() async {
    guard let client = _client else {
      logger.debug("Skipping heartbeat — no client available")
      return
    }

    do {
      // Ensure the endpoint routes through Nest
      await client.setServiceDID(Self.nestServiceDID, for: Self.heartbeatEndpoint)

      let input = BlueCatbirdBskychatPushHeartbeat.Input(platform: "ios")
      let (responseCode, _) = try await client.blue.catbird.bskychat.pushHeartbeat(input: input)

      if (200 ... 299).contains(responseCode) {
        logger.debug("Heartbeat sent successfully")
      } else {
        logger.warning("Heartbeat returned HTTP \(responseCode)")
      }
    } catch {
      logger.warning("Heartbeat failed: \(error.localizedDescription)")
    }
  }
}
#endif
