import Foundation
import OSLog
import WebKit

// MARK: - TileChatChannel

/// Enables tile-to-tile communication within a chat context
/// Each tile instance in a conversation can post and listen on a shared data channel
/// This allows tiles to sync state across participants (e.g., collaborative games, shared docs)
///
/// NOTE: The DASL spec states chat channels are planned for a future version.
/// This is the foundational API that will be connected to MLS data channels.
@available(iOS 26.0, macOS 26.0, *)
actor TileChatChannel {
  /// Unique identifier for this channel (typically the conversation/group ID)
  let channelID: String

  /// Listeners registered for incoming messages
  private var listeners: [UUID: AsyncStream<TileChatMessage>.Continuation] = [:]
  private let logger = Logger(subsystem: "blue.catbird", category: "TileChatChannel")

  init(channelID: String) {
    self.channelID = channelID
  }

  // MARK: - Public API

  /// Post a message to the channel (broadcast to all tile instances)
  func post(_ message: TileChatMessage) {
    logger.debug("Channel \(self.channelID): posting message type=\(message.type)")
    for (_, continuation) in listeners {
      continuation.yield(message)
    }
  }

  /// Listen for messages on the channel
  func listen() -> AsyncStream<TileChatMessage> {
    let id = UUID()
    return AsyncStream { continuation in
      continuation.onTermination = { [weak self] _ in
        Task { await self?.removeListener(id) }
      }
      Task { await self.addListener(id, continuation: continuation) }
    }
  }

  /// Close the channel and notify all listeners
  func close() {
    for (_, continuation) in listeners {
      continuation.finish()
    }
    listeners.removeAll()
  }

  // MARK: - Private

  private func addListener(_ id: UUID, continuation: AsyncStream<TileChatMessage>.Continuation) {
    listeners[id] = continuation
  }

  private func removeListener(_ id: UUID) {
    listeners.removeValue(forKey: id)
  }
}

// MARK: - TileChatMessage

/// A message sent between tile instances over the chat channel
struct TileChatMessage: Codable, Sendable {
  /// Message type identifier (application-defined)
  let type: String
  /// JSON-encoded payload
  let data: String
  /// Sender identifier (DID of the user whose tile instance sent this)
  let senderDID: String?
  /// Timestamp
  let timestamp: Date

  init(type: String, data: String, senderDID: String? = nil) {
    self.type = type
    self.data = data
    self.senderDID = senderDID
    self.timestamp = Date()
  }
}

// MARK: - TileChatBridge

/// Bridges between the tile's JavaScript context and the native chat channel
/// Injects a `tileChannel` API into the WebPage's content world
@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class TileChatBridge {
  private let channel: TileChatChannel
  private let logger = Logger(subsystem: "blue.catbird", category: "TileChatBridge")

  init(channel: TileChatChannel) {
    self.channel = channel
  }

  /// JavaScript API that will be injected into the tile's content world
  /// Tiles can call:
  ///   - tileChannel.post({ type: "move", data: JSON.stringify({x: 1, y: 2}) })
  ///   - tileChannel.onMessage((msg) => { ... })
  static let bridgeScript = """
    window.tileChannel = {
      _listeners: [],
      post: function(message) {
        window.webkit.messageHandlers.tileChannelPost.postMessage(JSON.stringify(message));
      },
      onMessage: function(callback) {
        this._listeners.push(callback);
      },
      _receive: function(message) {
        const parsed = JSON.parse(message);
        this._listeners.forEach(cb => cb(parsed));
      }
    };
    """

  /// Deliver a received message to the tile's JavaScript context
  func deliver(_ message: TileChatMessage, to page: WebPage) async {
    do {
      let messageJSON = try JSONEncoder().encode(message)
      let jsonString = String(data: messageJSON, encoding: .utf8) ?? "{}"
      let escaped = jsonString
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")

      _ = try await page.callJavaScript(
        "window.tileChannel._receive('\(escaped)')"
      )
    } catch {
      logger.error("Failed to deliver message to tile: \(error.localizedDescription)")
    }
  }
}
