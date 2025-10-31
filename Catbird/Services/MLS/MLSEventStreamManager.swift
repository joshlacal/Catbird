import Foundation
import Petrel
import OSLog

/// Manages SSE (Server-Sent Events) subscriptions for MLS conversations
/// Provides real-time message delivery, reactions, and typing indicators
@MainActor
public final class MLSEventStreamManager: ObservableObject {
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSEventStream")
    
    // MARK: - Properties
    
    private let apiClient: MLSAPIClient
    private var activeSubscriptions: [String: Task<Void, Never>] = [:]
    private var eventHandlers: [String: EventHandler] = [:]
    
    @Published public private(set) var connectionState: [String: ConnectionState] = [:]
    @Published public private(set) var lastCursor: [String: String] = [:]
    
    // MARK: - Types
    
    public enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case error(Error)
    }
    
    public struct EventHandler {
        var onMessage: ((BlueCatbirdMlsStreamConvoEvents.MessageEvent) async -> Void)?
        var onReaction: ((BlueCatbirdMlsStreamConvoEvents.ReactionEvent) async -> Void)?
        var onTyping: ((BlueCatbirdMlsStreamConvoEvents.TypingEvent) async -> Void)?
        var onInfo: ((BlueCatbirdMlsStreamConvoEvents.InfoEvent) async -> Void)?
        var onError: ((Error) async -> Void)?
    }
    
    // MARK: - Initialization
    
     init(apiClient: MLSAPIClient) {
        self.apiClient = apiClient
    }
    
    
    // MARK: - Public Methods
    
    /// Subscribe to real-time events for a conversation
    /// - Parameters:
    ///   - convoId: Conversation ID to subscribe to
    ///   - cursor: Optional cursor to resume from (for reconnection)
    ///   - handler: Event handler for different event types
    public func subscribe(
        to convoId: String,
        cursor: String? = nil,
        handler: EventHandler
    ) {
        logger.info("Subscribing to conversation: \(convoId)")
        
        // Stop existing subscription if any
        stop(convoId)
        
        // Store handler
        eventHandlers[convoId] = handler
        
        // Update state
        connectionState[convoId] = .connecting
        
        // Start subscription task
        let task = Task { [weak self] in
            await self?.runSubscription(convoId: convoId, cursor: cursor)
            return ()
        }
        
        activeSubscriptions[convoId] = task
    }
    
    /// Stop subscription for a specific conversation
    /// - Parameter convoId: Conversation ID
    public func stop(_ convoId: String) {
        logger.info("Stopping subscription for: \(convoId)")
        
        activeSubscriptions[convoId]?.cancel()
        activeSubscriptions.removeValue(forKey: convoId)
        eventHandlers.removeValue(forKey: convoId)
        connectionState[convoId] = .disconnected
    }
    
    /// Stop all active subscriptions
    public func stopAll() {
        logger.info("Stopping all subscriptions")
        
        for convoId in activeSubscriptions.keys {
            stop(convoId)
        }
    }
    
    /// Reconnect to a conversation (using last cursor)
    /// - Parameter convoId: Conversation ID
    public func reconnect(_ convoId: String) {
        guard let handler = eventHandlers[convoId] else {
            logger.warning("No handler found for reconnection: \(convoId)")
            return
        }
        
        logger.info("Reconnecting to conversation: \(convoId)")
        
        let cursor = lastCursor[convoId]
        subscribe(to: convoId, cursor: cursor, handler: handler)
    }
    
    // MARK: - Private Methods
    
    private func runSubscription(convoId: String, cursor: String?) async {
        var reconnectAttempts = 0
        let maxReconnectAttempts = 5
        let reconnectDelay: TimeInterval = 2.0
        
        while !Task.isCancelled && reconnectAttempts < maxReconnectAttempts {
            do {
                // Connect to SSE event stream
                logger.debug("Connecting to SSE stream for: \(convoId), cursor: \(cursor ?? "nil")")
                
                connectionState[convoId] = .connecting
                
                // Get event stream from API client via SSE
                let eventStream = try await apiClient.streamConvoEvents(
                    convoId: convoId,
                    cursor: cursor
                )
                
                connectionState[convoId] = .connected
                
                // Process events from stream
                for try await output in eventStream {
                    await handleEvent(output, for: convoId)
                }
                
                // If we reach here, connection was closed normally
                logger.info("SSE connection closed normally for: \(convoId)")
                connectionState[convoId] = .disconnected
                break
                
            } catch {
                logger.error("SSE connection error for \(convoId): \(error.localizedDescription)")
                
                connectionState[convoId] = .error(error)
                
                // Notify error handler
                if let handler = eventHandlers[convoId], let errorHandler = handler.onError {
                    await errorHandler(error)
                }
                
                // Attempt reconnect
                if !Task.isCancelled {
                    reconnectAttempts += 1
                    
                    if reconnectAttempts < maxReconnectAttempts {
                        logger.info("Attempting reconnect \(reconnectAttempts)/\(maxReconnectAttempts) for: \(convoId)")
                        connectionState[convoId] = .reconnecting
                        
                        try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * Double(reconnectAttempts) * 1_000_000_000))
                    }
                }
            }
        }
        
        if reconnectAttempts >= maxReconnectAttempts {
            logger.error("Max reconnect attempts reached for: \(convoId)")
            connectionState[convoId] = .disconnected
        }
    }
    
    private func handleEvent(_ output: BlueCatbirdMlsStreamConvoEvents.Output, for convoId: String) async {
        guard let handler = eventHandlers[convoId] else {
            return
        }

        logger.debug("Received event for conversation: \(convoId)")

        // Decode the event type from the raw data
        let decoder = JSONDecoder()

        // First, decode to get the $type discriminator
        guard let json = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any],
              let typeIdentifier = json["$type"] as? String else {
            logger.warning("Failed to extract $type from event data")
            return
        }

        // Decode the appropriate event type based on $type
        do {
            switch typeIdentifier {
            case BlueCatbirdMlsStreamConvoEvents.MessageEvent.typeIdentifier:
                let messageEvent = try decoder.decode(BlueCatbirdMlsStreamConvoEvents.MessageEvent.self, from: output.data)
                logger.debug("Message event: \(messageEvent.message.id)")
                lastCursor[convoId] = messageEvent.cursor
                await handler.onMessage?(messageEvent)

            case BlueCatbirdMlsStreamConvoEvents.ReactionEvent.typeIdentifier:
                let reactionEvent = try decoder.decode(BlueCatbirdMlsStreamConvoEvents.ReactionEvent.self, from: output.data)
                logger.debug("Reaction event: \(reactionEvent.action) - \(reactionEvent.reaction)")
                lastCursor[convoId] = reactionEvent.cursor
                await handler.onReaction?(reactionEvent)

            case BlueCatbirdMlsStreamConvoEvents.TypingEvent.typeIdentifier:
                let typingEvent = try decoder.decode(BlueCatbirdMlsStreamConvoEvents.TypingEvent.self, from: output.data)
                logger.debug("Typing event: \(typingEvent.did)")
                lastCursor[convoId] = typingEvent.cursor
                await handler.onTyping?(typingEvent)

            case BlueCatbirdMlsStreamConvoEvents.InfoEvent.typeIdentifier:
                let infoEvent = try decoder.decode(BlueCatbirdMlsStreamConvoEvents.InfoEvent.self, from: output.data)
                logger.debug("Info event: \(infoEvent.info)")
                lastCursor[convoId] = infoEvent.cursor
                await handler.onInfo?(infoEvent)

            default:
                logger.warning("Unexpected event type: \(typeIdentifier)")
            }
        } catch {
            logger.error("Failed to decode event: \(error.localizedDescription)")
        }
    }
}

// NOTE: SSE event stream implementation is now in MLSAPIClient.swift
