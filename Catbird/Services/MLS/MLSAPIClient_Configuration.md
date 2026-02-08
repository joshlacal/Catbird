# MLSAPIClient Configuration Guide

## Overview

The `MLSAPIClient` provides a robust interface for connecting to MLS (Message Layer Security) servers with support for multiple environments, automatic retry logic, and comprehensive error handling.

## Features

✅ **Environment Configuration**: Local, production, and custom server support  
✅ **Health Monitoring**: Built-in health checks with status tracking  
✅ **Network Resilience**: Automatic retry with exponential backoff  
✅ **Error Handling**: Detailed error types with network diagnostics  
✅ **Authentication**: Bearer token support with credential management  
✅ **Logging**: Comprehensive OSLog integration for debugging  

## Environment Configuration

### 1. Local Development (Default)

Connect to a local MLS server running on your development machine:

```swift
let client = MLSAPIClient(environment: .local)
// Connects to: http://localhost:8080
```

**Use Case**: Testing and development with local MLS server instance

### 2. Production

Connect to the production MLS server:

```swift
let client = MLSAPIClient(
    environment: .production,
    userDid: "did:plc:user123",
    authToken: "your-auth-token"
)
// Connects to: https://api.catbird.blue
```

**Use Case**: Production deployments with real users

### 3. Custom Server

Connect to any custom MLS server:

```swift
let customURL = URL(string: "https://staging.example.com")!
let client = MLSAPIClient(
    environment: .custom(customURL),
    userDid: "did:plc:user123",
    authToken: "your-auth-token"
)
```

**Use Case**: Staging, testing, or enterprise deployments

### 4. Dynamic Environment Switching

Switch between environments at runtime:

```swift
let client = MLSAPIClient(environment: .local)

// Later, switch to production
client.switchEnvironment(.production)
client.updateAuthentication(did: "did:plc:user123", token: "token")
await client.checkHealth()
```

## Health Check

The health check verifies server connectivity and availability before performing operations.

### Basic Health Check

```swift
let client = MLSAPIClient(environment: .local)

if await client.checkHealth() {
    print("✅ Server is healthy and responding")
} else {
    print("❌ Server is not available")
}
```

### Health Status Properties

```swift
// Check if server is currently healthy
if client.isHealthy {
    print("Server is healthy")
}

// Get last health check time
if let lastCheck = client.lastHealthCheck {
    print("Last checked: \(lastCheck)")
}
```

### Health Check Response

The server can optionally return health metadata:

```json
{
  "status": "healthy",
  "version": "1.0.0",
  "timestamp": "2024-01-15T10:30:00Z"
}
```

## Error Handling

### Error Types

The client uses `MLSAPIError` enum for all API-related errors:

```swift
enum MLSAPIError: Error {
    case noAuthentication          // Missing auth credentials
    case invalidResponse           // Malformed server response
    case httpError(Int, String)    // HTTP errors with status and message
    case decodingError(Error)      // JSON decoding failures
    case networkError(URLError)    // Network connectivity issues
    case blobTooLarge             // File upload too large (>50MB)
    case serverUnavailable        // Server not responding
    case unknownError             // Unexpected errors
}
```

### Comprehensive Error Handling

```swift
do {
    let (conversations, _) = try await client.getConversations()
    print("Loaded \(conversations.count) conversations")
    
} catch MLSAPIError.networkError(let urlError) {
    // Handle network errors
    switch urlError.code {
    case .notConnectedToInternet:
        showAlert("No internet connection")
    case .cannotConnectToHost:
        showAlert("Cannot connect to MLS server")
    case .timedOut:
        showAlert("Request timed out")
    default:
        showAlert("Network error: \(urlError.localizedDescription)")
    }
    
} catch MLSAPIError.noAuthentication {
    // User needs to authenticate
    presentLoginScreen()
    
} catch MLSAPIError.httpError(let status, let message) {
    // HTTP errors
    if status == 401 {
        // Unauthorized - refresh token
        await refreshAuthToken()
    } else if status == 404 {
        // Not found
        showAlert("Resource not found")
    } else {
        showAlert("Error \(status): \(message)")
    }
    
} catch MLSAPIError.serverUnavailable {
    // Server is down
    showAlert("MLS server is temporarily unavailable")
    
} catch {
    // Unknown error
    showAlert("An unexpected error occurred: \(error.localizedDescription)")
}
```

### Network Error Diagnostics

The client automatically logs detailed network errors:

```swift
// Automatic logging for:
// - No internet connection
// - Cannot connect to host
// - Connection lost
// - Request timeout
// - DNS lookup failures
// - And more...
```

## Retry Logic

### Automatic Retry

The client automatically retries failed requests with configurable settings:

```swift
let client = MLSAPIClient(
    environment: .local,
    maxRetries: 3,        // Retry up to 3 times
    retryDelay: 1.0       // Wait 1 second between retries
)
```

### Retry Behavior

- **Network Errors**: Automatically retried (connection issues, timeouts)
- **5xx Server Errors**: Automatically retried (server-side issues)
- **4xx Client Errors**: NOT retried (invalid requests, auth failures)
- **Successful Responses**: No retry needed

### Retry Strategy

1. **Attempt 1**: Immediate request
2. **Attempt 2**: Wait `retryDelay` seconds, then retry
3. **Attempt 3**: Wait `retryDelay` seconds, then retry
4. **Final**: Return last error if all attempts fail

## Authentication

### Setting Authentication

```swift
let client = MLSAPIClient(environment: .production)

// Set auth credentials
client.updateAuthentication(
    did: "did:plc:user123",
    token: "jwt-token-here"
)
```

### Clearing Authentication

```swift
// Clear credentials (e.g., on logout)
client.clearAuthentication()
```

### Authentication Flow

```swift
// 1. Initialize without auth
let client = MLSAPIClient(environment: .production)

// 2. Authenticate user
let (did, token) = await authenticateUser()
client.updateAuthentication(did: did, token: token)

// 3. Verify connectivity
guard await client.checkHealth() else {
    throw MLSAPIError.serverUnavailable
}

// 4. Use authenticated endpoints
let (conversations, _) = try await client.getConversations()
```

## Timeout Configuration

The client uses sensible timeout defaults:

```swift
// Request timeout: 30 seconds
// Resource timeout: 60 seconds
// Health check timeout: 5 seconds
```

To customize timeouts, modify the URLSessionConfiguration:

```swift
let config = URLSessionConfiguration.default
config.timeoutIntervalForRequest = 45.0
config.timeoutIntervalForResource = 90.0
let session = URLSession(configuration: config)
// Use custom session in client implementation
```

## Best Practices

### 1. Always Check Health First

```swift
let client = MLSAPIClient(environment: .local)

guard await client.checkHealth() else {
    print("⚠️ MLS server is not running")
    print("Please start the local server: npm run dev")
    return
}

// Proceed with operations
```

### 2. Handle Network Errors Gracefully

```swift
do {
    let result = try await client.someOperation()
} catch MLSAPIError.networkError(let error) {
    // Show user-friendly error
    showRetryableError(error)
} catch {
    // Handle other errors
}
```

### 3. Use Environment Variables

```swift
#if DEBUG
let environment: MLSEnvironment = .local
#else
let environment: MLSEnvironment = .production
#endif

let client = MLSAPIClient(environment: environment)
```

### 4. Monitor Health Status

```swift
// Check health periodically
Task {
    while true {
        await client.checkHealth()
        try await Task.sleep(for: .seconds(60))
    }
}
```

### 5. Implement Retry UI

```swift
func loadConversations() async {
    do {
        let (conversations, _) = try await client.getConversations()
        self.conversations = conversations
    } catch MLSAPIError.networkError {
        // Show retry button
        showRetryButton {
            await self.loadConversations()
        }
    }
}
```

## Troubleshooting

### Local Server Not Connecting

**Problem**: Cannot connect to localhost:8080

**Solutions**:
1. Verify local MLS server is running: `ps aux | grep mls-server`
2. Check if port 8080 is in use: `lsof -i :8080`
3. Try health check: `curl http://localhost:8080/health`
4. Check firewall settings
5. Verify server logs for errors

### Authentication Failures

**Problem**: 401 Unauthorized errors

**Solutions**:
1. Verify token is valid and not expired
2. Check DID format is correct
3. Ensure Bearer token format: `"Bearer <token>"`
4. Refresh authentication token
5. Re-authenticate user

### Timeout Issues

**Problem**: Requests timing out

**Solutions**:
1. Check network connectivity
2. Increase timeout values
3. Verify server is responding: health check
4. Check server load/performance
5. Reduce request payload size

### Decoding Errors

**Problem**: Failed to decode server response

**Solutions**:
1. Verify API version compatibility
2. Check server response format
3. Enable debug logging to see raw response
4. Update client models to match server schema
5. Check for breaking API changes

## Example: Complete Application Setup

```swift
import SwiftUI

@main
struct MyApp: App {
    @StateObject private var mlsClient: MLSClientManager
    
    init() {
        // Configure environment
        #if DEBUG
        let environment = MLSEnvironment.local
        #else
        let environment = MLSEnvironment.production
        #endif
        
        _mlsClient = StateObject(wrappedValue: MLSClientManager(
            environment: environment
        ))
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(mlsClient)
                .task {
                    // Perform initial health check
                    await mlsClient.initialize()
                }
        }
    }
}

@MainActor
class MLSClientManager: ObservableObject {
    @Published var isHealthy = false
    @Published var error: MLSAPIError?
    
    let client: MLSAPIClient
    
    init(environment: MLSEnvironment) {
        self.client = MLSAPIClient(
            environment: environment,
            maxRetries: 3,
            retryDelay: 1.0
        )
    }
    
    func initialize() async {
        isHealthy = await client.checkHealth()
        
        if !isHealthy {
            error = .serverUnavailable
        }
    }
    
    func authenticate(did: String, token: String) {
        client.updateAuthentication(did: did, token: token)
    }
}
```

## Logging

All operations are logged using OSLog:

```swift
import OSLog

let logger = Logger(subsystem: "blue.catbird", category: "MLSAPIClient")

// View logs in Console.app:
// Filter by: subsystem:blue.catbird category:MLSAPIClient
```

## API Reference

See `MLSAPIClient.swift` for complete API documentation including:

- 9 MLS API endpoints
- Request/response models
- Authentication methods
- Configuration options
- Error types

## Support

For issues or questions:

1. Check server health: `await client.checkHealth()`
2. Review Console.app logs for detailed errors
3. Verify environment configuration
4. Consult API documentation
5. Check network connectivity

## Version History

- **v1.0**: Initial implementation with environment support, health checks, and retry logic
