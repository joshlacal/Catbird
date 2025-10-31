import Foundation
import OSLog

/// Server-Sent Events (SSE) client for receiving real-time updates
/// Implements the EventSource/SSE protocol over URLSession
public final class SSEClient: NSObject {
    private let sseLogger = Logger(subsystem: "blue.catbird", category: "SSEClient")
    
    // MARK: - Properties
    
    private let url: URL
    private let authToken: String?
    private let session: URLSession
    private var dataTask: URLSessionDataTask?
    private var buffer: Data = Data()
    
    public var onEvent: ((SSEEvent) -> Void)?
    public var onError: ((Error) -> Void)?
    public var onOpen: (() -> Void)?
    public var onClose: (() -> Void)?
    
    private var isConnected = false
    private var lastEventId: String?
    
    // MARK: - Types
    
    public struct SSEEvent {
        public let id: String?
        public let event: String?
        public let data: String
        public let retry: TimeInterval?
        
        public init(id: String? = nil, event: String? = nil, data: String, retry: TimeInterval? = nil) {
            self.id = id
            self.event = event
            self.data = data
            self.retry = retry
        }
    }
    
    public enum SSEError: Error {
        case invalidURL
        case connectionFailed(Error)
        case invalidResponse
        case streamClosed
        case unauthorized
    }
    
    // MARK: - Initialization
    
    public init(url: URL, authToken: String? = nil) {
        self.url = url
        self.authToken = authToken
        
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = .infinity
        configuration.timeoutIntervalForResource = .infinity
        configuration.httpAdditionalHeaders = [
            "Accept": "text/event-stream",
            "Cache-Control": "no-cache"
        ]
        
        if let token = authToken {
            configuration.httpAdditionalHeaders?["Authorization"] = "Bearer \(token)"
        }
        
        self.session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        
        super.init()
    }
    
    // MARK: - Public Methods
    
    /// Connect to the SSE stream
    public func connect() {
        guard !isConnected else {
            sseLogger.warning("Already connected to SSE stream")
            return
        }
        
        sseLogger.info("Connecting to SSE stream: \(self.url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        if let lastId = lastEventId {
            request.setValue(lastId, forHTTPHeaderField: "Last-Event-ID")
        }
        
        dataTask = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                self.sseLogger.error("SSE connection error: \(error.localizedDescription)")
                self.isConnected = false
                self.onError?(SSEError.connectionFailed(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                self.sseLogger.error("Invalid SSE response")
                self.isConnected = false
                self.onError?(SSEError.invalidResponse)
                return
            }
            
            if httpResponse.statusCode == 401 {
                self.sseLogger.error("SSE unauthorized")
                self.isConnected = false
                self.onError?(SSEError.unauthorized)
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                self.sseLogger.error("SSE error status: \(httpResponse.statusCode)")
                self.isConnected = false
                self.onError?(SSEError.invalidResponse)
                return
            }
            
            // Connection successful
            self.isConnected = true
            self.onOpen?()
            self.sseLogger.info("SSE connection established")
        }
        
        // Start receiving data incrementally
        dataTask?.resume()
    }
    
    /// Disconnect from the SSE stream
    public func disconnect() {
        sseLogger.info("Disconnecting from SSE stream")
        
        dataTask?.cancel()
        dataTask = nil
        isConnected = false
        buffer.removeAll()
        onClose?()
    }
    
    // MARK: - Private Methods
    
    private func handleData(_ data: Data) {
        buffer.append(data)
        
        // Process complete events
        while let range = buffer.range(of: "\n\n".data(using: .utf8)!) {
            let eventData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            
            if let event = parseEvent(from: eventData) {
                handleEvent(event)
            }
        }
    }
    
    private func parseEvent(from data: Data) -> SSEEvent? {
        guard let eventString = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        var id: String?
        var event: String?
        var dataLines: [String] = []
        var retry: TimeInterval?
        
        for line in eventString.components(separatedBy: "\n") {
            if line.isEmpty || line.hasPrefix(":") {
                // Comment or empty line
                continue
            }
            
            let components = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else { continue }
            
            let field = String(components[0])
            let value = components[1].trimmingCharacters(in: .whitespaces)
            
            switch field {
            case "id":
                id = value
            case "event":
                event = value
            case "data":
                dataLines.append(value)
            case "retry":
                if let retryValue = TimeInterval(value) {
                    retry = retryValue / 1000.0  // Convert ms to seconds
                }
            default:
                break
            }
        }
        
        guard !dataLines.isEmpty else {
            return nil
        }
        
        let eventData = dataLines.joined(separator: "\n")
        return SSEEvent(id: id, event: event, data: eventData, retry: retry)
    }
    
    private func handleEvent(_ event: SSEEvent) {
        // Update last event ID
        if let id = event.id {
            lastEventId = id
        }
        
        // Log event
        let eventType = event.event ?? "message"
        sseLogger.debug("SSE event received: \(eventType), id: \(event.id ?? "nil")")
        
        // Notify handler
        onEvent?(event)
    }
}

// MARK: - URLSessionDataDelegate

extension SSEClient: URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handleData(data)
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        isConnected = false
        
        if let error = error {
            sseLogger.error("SSE connection closed with error: \(error.localizedDescription)")
            onError?(SSEError.connectionFailed(error))
        } else {
            sseLogger.info("SSE connection closed normally")
            onClose?()
        }
    }
}
