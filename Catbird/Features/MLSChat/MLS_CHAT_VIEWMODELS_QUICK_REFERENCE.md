# MLS Chat View Models Quick Reference

## Import and Initialize

```swift
import Combine

// Initialize API client
let apiClient = MLSAPIClient()

// Initialize view models
let listVM = MLSConversationListViewModel(apiClient: apiClient)
let detailVM = MLSConversationDetailViewModel(conversationId: "convo-id", apiClient: apiClient)
let newConvoVM = MLSNewConversationViewModel(apiClient: apiClient)
let memberVM = MLSMemberManagementViewModel(conversationId: "convo-id", apiClient: apiClient)
```

## MLSConversationListViewModel

### Properties
```swift
var conversations: [MLSConvoView]           // List of conversations
var isLoading: Bool                         // Loading state
var error: Error?                           // Error state
var hasMore: Bool                           // Has more pages
var searchQuery: String                     // Search query
var filteredConversations: [MLSConvoView]   // Filtered results
```

### Methods
```swift
await loadConversations()                   // Load initial conversations
await loadMoreConversations()               // Load next page
await refresh()                             // Refresh list
await deleteConversationLocally(id)         // Remove from list
await updateConversation(convo)             // Update conversation
await addConversation(convo)                // Add new conversation
clearError()                                // Clear error state
```

### Publishers
```swift
conversationsPublisher  // Emits [MLSConvoView]
errorPublisher          // Emits Error
```

### Usage
```swift
// Load conversations
Task {
    await viewModel.loadConversations()
}

// Subscribe to updates
viewModel.conversationsPublisher
    .sink { conversations in
        // Update UI
    }
    .store(in: &cancellables)

// Search
viewModel.searchQuery = "test"
```

## MLSConversationDetailViewModel

### Properties
```swift
var conversation: MLSConvoView?             // Current conversation
var messages: [MLSMessageView]              // Messages list
var isLoadingConversation: Bool             // Loading conversation
var isLoadingMessages: Bool                 // Loading messages
var isSendingMessage: Bool                  // Sending message
var isLeavingConversation: Bool             // Leaving conversation
var error: Error?                           // Error state
var hasMoreMessages: Bool                   // Has more pages
var draftMessage: String                    // Draft message text
var isTyping: Bool                          // Typing indicator
```

### Methods
```swift
await loadConversation()                    // Load conversation & messages
await loadMessages()                        // Load messages only
await loadMoreMessages()                    // Load older messages
await sendMessage(text)                     // Send message
try await leaveConversation()               // Leave conversation
await setTyping(true/false)                 // Update typing status
await refresh()                             // Refresh all data
clearError()                                // Clear error state
```

### Publishers
```swift
messagesPublisher       // Emits [MLSMessageView]
conversationPublisher   // Emits MLSConvoView
errorPublisher          // Emits Error
```

### Usage
```swift
// Load conversation
Task {
    await viewModel.loadConversation()
}

// Send message
Task {
    await viewModel.sendMessage("Hello!")
}

// Leave conversation
Task {
    try await viewModel.leaveConversation()
}

// Typing indicator
await viewModel.setTyping(true)  // Auto-expires in 3s
```

## MLSNewConversationViewModel

### Properties
```swift
var selectedMembers: [String]               // Selected member DIDs
var conversationName: String                // Conversation name
var conversationDescription: String         // Description
var selectedCipherSuite: String             // Selected cipher
var isCreating: Bool                        // Creating state
var error: Error?                           // Error state
var memberSearchQuery: String               // Member search
var searchResults: [String]                 // Search results
var isSearching: Bool                       // Searching state
var availableCipherSuites: [String]         // Available ciphers
var isValid: Bool                           // Form validation
```

### Methods
```swift
await createConversation()                  // Create conversation
await addMember(did)                        // Add member
await removeMember(did)                     // Remove member
await toggleMember(did)                     // Toggle member
await reset()                               // Reset form
validate() -> [String]                      // Validate form
clearError()                                // Clear error
```

### Publishers
```swift
conversationCreatedPublisher  // Emits MLSConvoView
errorPublisher                // Emits Error
```

### Usage
```swift
// Set up conversation
viewModel.conversationName = "My Group"
viewModel.conversationDescription = "A test group"
await viewModel.addMember("did:plc:user1")
await viewModel.addMember("did:plc:user2")

// Validate
let errors = viewModel.validate()
if errors.isEmpty {
    // Create
    Task {
        await viewModel.createConversation()
    }
}

// Subscribe to creation
viewModel.conversationCreatedPublisher
    .sink { conversation in
        // Navigate to conversation
    }
    .store(in: &cancellables)
```

## MLSMemberManagementViewModel

### Properties
```swift
var conversation: MLSConvoView?             // Current conversation
var members: [MLSMemberView]                // Members list
var isLoadingMembers: Bool                  // Loading state
var isAddingMembers: Bool                   // Adding state
var isRemovingMember: Bool                  // Removing state
var error: Error?                           // Error state
var pendingMembers: [String]                // Pending members
var memberSearchQuery: String               // Search query
var searchResults: [String]                 // Search results
var isSearching: Bool                       // Searching state
```

### Methods
```swift
await loadMembers()                         // Load members
await addMembers([did])                     // Add members
await addPendingMember(did)                 // Add to pending
await removePendingMember(did)              // Remove from pending
await commitPendingMembers()                // Add pending members
getMemberDisplayName(member) -> String      // Get display name
canManageMembers(userDid) -> Bool           // Check permissions
await refresh()                             // Refresh members
clearError()                                // Clear error
await clearSearch()                         // Clear search
validateDid(did) -> Bool                    // Validate DID format
```

### Publishers
```swift
membersUpdatedPublisher         // Emits [MLSMemberView]
conversationUpdatedPublisher    // Emits MLSConvoView
errorPublisher                  // Emits Error
```

### Usage
```swift
// Load members
Task {
    await viewModel.loadMembers()
}

// Add members
await viewModel.addPendingMember("did:plc:user1")
await viewModel.addPendingMember("did:plc:user2")
await viewModel.commitPendingMembers()

// Check permissions
if viewModel.canManageMembers(userDid: currentUserDid) {
    // Show add member UI
}

// Subscribe to updates
viewModel.membersUpdatedPublisher
    .sink { members in
        // Update UI
    }
    .store(in: &cancellables)
```

## Error Handling Pattern

All view models follow this pattern:

```swift
do {
    try await operation()
} catch {
    viewModel.error = error
    errorSubject.send(error)
}

// In UI
viewModel.errorPublisher
    .sink { error in
        // Show error alert
    }
    .store(in: &cancellables)

// Or check directly
if let error = viewModel.error {
    // Show error
}

// Clear error
viewModel.clearError()
```

## Loading State Pattern

```swift
// Check before operation
guard !viewModel.isLoading else { return }

// Set loading
viewModel.isLoading = true

// Perform operation
// ...

// Clear loading
viewModel.isLoading = false

// In UI
if viewModel.isLoading {
    ProgressView()
}
```

## Combine Subscription Pattern

```swift
// Create cancellables set
private var cancellables = Set<AnyCancellable>()

// Subscribe
viewModel.dataPublisher
    .sink { data in
        // Handle data
    }
    .store(in: &cancellables)

// Cleanup (in deinit or tearDown)
cancellables.forEach { $0.cancel() }
cancellables = nil
```

## Common Patterns

### Refresh Pattern
```swift
// Pull to refresh
await viewModel.refresh()
```

### Pagination Pattern
```swift
// On scroll to bottom
if viewModel.hasMore && !viewModel.isLoading {
    await viewModel.loadMoreConversations()
}
```

### Search Pattern
```swift
// Debounced search via property observer
viewModel.searchQuery = searchText
// Auto-triggers search after property change
```

### Validation Pattern
```swift
// Check validity
if viewModel.isValid {
    // Enable submit button
}

// Or get detailed errors
let errors = viewModel.validate()
for error in errors {
    // Show error message
}
```

## Testing

```swift
import XCTest
@testable import Catbird

@MainActor
final class MyViewModelTests: XCTestCase {
    var viewModel: MLSConversationListViewModel!
    var mockAPIClient: MockMLSAPIClient!
    var cancellables: Set<AnyCancellable>!
    
    override func setUp() async throws {
        mockAPIClient = MockMLSAPIClient()
        viewModel = MLSConversationListViewModel(apiClient: mockAPIClient)
        cancellables = Set<AnyCancellable>()
    }
    
    override func tearDown() async throws {
        cancellables.forEach { $0.cancel() }
        cancellables = nil
        viewModel = nil
        mockAPIClient = nil
    }
    
    func testExample() async {
        // Given
        let expectation = XCTestExpectation(description: "Test")
        
        // Subscribe
        viewModel.conversationsPublisher.sink { _ in
            expectation.fulfill()
        }.store(in: &cancellables)
        
        // When
        await viewModel.loadConversations()
        
        // Then
        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertFalse(viewModel.conversations.isEmpty)
    }
}
```
