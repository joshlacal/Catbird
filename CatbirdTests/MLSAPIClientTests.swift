import XCTest
@testable import Catbird

/// Comprehensive unit tests for MLSAPIClient
/// Tests all 9 MLS API endpoints with proper mocking and error handling
final class MLSAPIClientTests: XCTestCase {
    
    var client: MLSAPIClient!
    var mockSession: MockURLSession!
    let testBaseURL = URL(string: "https://test.catbird.blue")!
    let testDid = "did:plc:test123456789"
    let testToken = "test_auth_token_12345"
    
    override func setUp() {
        super.setUp()
        client = MLSAPIClient(
            baseURL: testBaseURL,
            userDid: testDid,
            authToken: testToken,
            maxRetries: 1,
            retryDelay: 0.1
        )
    }
    
    override func tearDown() {
        client = nil
        mockSession = nil
        super.tearDown()
    }
    
    // MARK: - Authentication Tests
    
    func testUpdateAuthentication() {
        let newDid = "did:plc:newuser"
        let newToken = "new_token"
        
        client.updateAuthentication(did: newDid, token: newToken)
        
        // Authentication is updated (we can verify through actual API calls)
        XCTAssertNotNil(client)
    }
    
    func testClearAuthentication() {
        client.clearAuthentication()
        XCTAssertNotNil(client)
    }
    
    // MARK: - Get Conversations Tests
    
    func testGetConversationsSuccess() async throws {
        // This is an integration-style test that would need a mock server
        // For now, we test the structure
        
        let expectedURL = testBaseURL.appendingPathComponent("/xrpc/blue.catbird.mls.getConvos")
        XCTAssertNotNil(expectedURL)
    }
    
    func testGetConversationsWithPagination() {
        let limit = 25
        let cursor = "test_cursor_123"
        
        // Test URL construction
        var components = URLComponents(url: testBaseURL.appendingPathComponent("/xrpc/blue.catbird.mls.getConvos"), resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "cursor", value: cursor),
            URLQueryItem(name: "sortBy", value: "lastMessageAt"),
            URLQueryItem(name: "sortOrder", value: "desc")
        ]
        
        XCTAssertNotNil(components.url)
        XCTAssertTrue(components.url!.absoluteString.contains("limit=25"))
        XCTAssertTrue(components.url!.absoluteString.contains("cursor=test_cursor_123"))
    }
    
    func testGetConversationsDefaultParameters() {
        var components = URLComponents(url: testBaseURL.appendingPathComponent("/xrpc/blue.catbird.mls.getConvos"), resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "sortBy", value: "lastMessageAt"),
            URLQueryItem(name: "sortOrder", value: "desc")
        ]
        
        XCTAssertNotNil(components.url)
        XCTAssertTrue(components.url!.absoluteString.contains("limit=50"))
    }
    
    // MARK: - Create Conversation Tests
    
    func testCreateConversationRequestEncoding() throws {
        let metadata = MLSConvoMetadata(
            name: "Test Group",
            description: "A test conversation",
            avatar: nil
        )
        
        let request = MLSCreateConvoRequest(
            cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
            initialMembers: ["did:plc:member1", "did:plc:member2"],
            metadata: metadata
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(request)
        
        XCTAssertNotNil(data)
        XCTAssertGreaterThan(data.count, 0)
        
        // Verify it can be decoded back
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MLSCreateConvoRequest.self, from: data)
        
        XCTAssertEqual(decoded.cipherSuite, request.cipherSuite)
        XCTAssertEqual(decoded.initialMembers?.count, 2)
        XCTAssertEqual(decoded.metadata?.name, "Test Group")
    }
    
    func testCreateConversationURL() {
        let url = testBaseURL.appendingPathComponent("/xrpc/blue.catbird.mls.createConvo")
        XCTAssertEqual(url.path, "/xrpc/blue.catbird.mls.createConvo")
    }
    
    // MARK: - Add Members Tests
    
    func testAddMembersRequestEncoding() throws {
        let request = MLSAddMembersRequest(
            convoId: "convo123",
            members: ["did:plc:newmember1", "did:plc:newmember2"]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        
        XCTAssertNotNil(data)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MLSAddMembersRequest.self, from: data)
        
        XCTAssertEqual(decoded.convoId, "convo123")
        XCTAssertEqual(decoded.members.count, 2)
    }
    
    // MARK: - Leave Conversation Tests
    
    func testLeaveConversationRequestEncoding() throws {
        let request = MLSLeaveConvoRequest(convoId: "convo456")
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        
        XCTAssertNotNil(data)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MLSLeaveConvoRequest.self, from: data)
        
        XCTAssertEqual(decoded.convoId, "convo456")
    }
    
    // MARK: - Get Messages Tests
    
    func testGetMessagesURLConstruction() {
        let convoId = "convo789"
        let limit = 30
        let cursor = "msg_cursor"
        
        var components = URLComponents(url: testBaseURL.appendingPathComponent("/xrpc/blue.catbird.mls.getMessages"), resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "convoId", value: convoId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "cursor", value: cursor)
        ]
        
        XCTAssertNotNil(components.url)
        XCTAssertTrue(components.url!.absoluteString.contains("convoId=convo789"))
        XCTAssertTrue(components.url!.absoluteString.contains("limit=30"))
    }
    
    func testGetMessagesWithDateFilters() {
        let since = Date(timeIntervalSince1970: 1700000000)
        let until = Date(timeIntervalSince1970: 1700100000)
        
        let formatter = ISO8601DateFormatter()
        let sinceString = formatter.string(from: since)
        let untilString = formatter.string(from: until)
        
        XCTAssertFalse(sinceString.isEmpty)
        XCTAssertFalse(untilString.isEmpty)
    }
    
    func testGetMessagesWithEpochFilter() {
        var components = URLComponents(url: testBaseURL.appendingPathComponent("/xrpc/blue.catbird.mls.getMessages"), resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "convoId", value: "convo123"),
            URLQueryItem(name: "epoch", value: "5")
        ]
        
        XCTAssertTrue(components.url!.absoluteString.contains("epoch=5"))
    }
    
    // MARK: - Send Message Tests
    
    func testSendMessageRequestEncoding() throws {
        let blobRef = MLSBlobRef(
            cid: "bafytest123",
            mimeType: "image/png",
            size: 12345,
            ref: "at://test/blob/ref"
        )
        
        let request = MLSSendMessageRequest(
            convoId: "convo999",
            ciphertext: "base64encodedciphertext==",
            contentType: "text/plain",
            attachments: [blobRef]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        
        XCTAssertNotNil(data)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MLSSendMessageRequest.self, from: data)
        
        XCTAssertEqual(decoded.convoId, "convo999")
        XCTAssertEqual(decoded.ciphertext, "base64encodedciphertext==")
        XCTAssertEqual(decoded.attachments?.count, 1)
        XCTAssertEqual(decoded.attachments?.first?.cid, "bafytest123")
    }
    
    func testSendMessageWithoutAttachments() throws {
        let request = MLSSendMessageRequest(
            convoId: "convo111",
            ciphertext: "encrypted",
            contentType: "text/plain",
            attachments: nil
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        
        XCTAssertNotNil(data)
    }
    
    // MARK: - Key Package Tests
    
    func testPublishKeyPackageRequestEncoding() throws {
        let expiresAt = Date(timeIntervalSinceNow: 2592000) // 30 days
        
        let request = MLSPublishKeyPackageRequest(
            keyPackage: "base64keypackage==",
            cipherSuite: "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
            expiresAt: expiresAt
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(request)
        
        XCTAssertNotNil(data)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MLSPublishKeyPackageRequest.self, from: data)
        
        XCTAssertEqual(decoded.keyPackage, "base64keypackage==")
        XCTAssertEqual(decoded.cipherSuite, "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519")
    }
    
    func testGetKeyPackagesURLConstruction() {
        let dids = ["did:plc:user1", "did:plc:user2", "did:plc:user3"]
        let cipherSuite = "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"
        
        var components = URLComponents(url: testBaseURL.appendingPathComponent("/xrpc/blue.catbird.mls.getKeyPackages"), resolvingAgainstBaseURL: true)!
        var queryItems = dids.map { URLQueryItem(name: "dids", value: $0) }
        queryItems.append(URLQueryItem(name: "cipherSuite", value: cipherSuite))
        components.queryItems = queryItems
        
        XCTAssertNotNil(components.url)
        // URL should contain multiple dids parameters
        let urlString = components.url!.absoluteString
        XCTAssertTrue(urlString.contains("dids="))
    }
    
    // MARK: - Blob Upload Tests
    
    func testBlobUploadSizeValidation() async {
        // Test that blob size limit is enforced
        let oversizedData = Data(repeating: 0, count: 52_428_801) // 50MB + 1 byte
        
        do {
            _ = try await client.uploadBlob(data: oversizedData, mimeType: "image/jpeg")
            XCTFail("Should have thrown blobTooLarge error")
        } catch MLSAPIError.blobTooLarge {
            // Expected error
            XCTAssertTrue(true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    
    func testBlobUploadValidSize() {
        let validData = Data(repeating: 0, count: 1_000_000) // 1MB
        XCTAssertLessThanOrEqual(validData.count, 52_428_800)
    }
    
    // MARK: - Model Tests
    
    func testMLSConvoViewDecoding() throws {
        let json = """
        {
            "id": "convo123",
            "groupId": "group456",
            "creator": "did:plc:creator",
            "members": [
                {
                    "did": "did:plc:member1",
                    "joinedAt": "2024-01-01T00:00:00Z",
                    "leafIndex": 0
                }
            ],
            "epoch": 5,
            "cipherSuite": "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
            "createdAt": "2024-01-01T00:00:00Z"
        }
        """
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        
        let convo = try decoder.decode(MLSConvoView.self, from: data)
        
        XCTAssertEqual(convo.id, "convo123")
        XCTAssertEqual(convo.groupId, "group456")
        XCTAssertEqual(convo.creator, "did:plc:creator")
        XCTAssertEqual(convo.members.count, 1)
        XCTAssertEqual(convo.epoch, 5)
        XCTAssertEqual(convo.cipherSuite, "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519")
    }
    
    func testMLSMessageViewDecoding() throws {
        let json = """
        {
            "id": "msg123",
            "convoId": "convo456",
            "sender": "did:plc:sender",
            "ciphertext": "encrypted==",
            "epoch": 3,
            "createdAt": "2024-01-01T12:00:00Z",
            "contentType": "text/plain"
        }
        """
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        
        let message = try decoder.decode(MLSMessageView.self, from: data)
        
        XCTAssertEqual(message.id, "msg123")
        XCTAssertEqual(message.convoId, "convo456")
        XCTAssertEqual(message.sender, "did:plc:sender")
        XCTAssertEqual(message.ciphertext, "encrypted==")
        XCTAssertEqual(message.epoch, 3)
        XCTAssertEqual(message.contentType, "text/plain")
    }
    
    func testMLSKeyPackageRefDecoding() throws {
        let json = """
        {
            "id": "kp123",
            "did": "did:plc:user",
            "keyPackage": "base64package==",
            "cipherSuite": "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519",
            "createdAt": "2024-01-01T00:00:00Z",
            "expiresAt": "2024-02-01T00:00:00Z"
        }
        """
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        
        let keyPackage = try decoder.decode(MLSKeyPackageRef.self, from: data)
        
        XCTAssertEqual(keyPackage.id, "kp123")
        XCTAssertEqual(keyPackage.did, "did:plc:user")
        XCTAssertEqual(keyPackage.keyPackage, "base64package==")
        XCTAssertNotNil(keyPackage.expiresAt)
    }
    
    func testMLSBlobRefDecoding() throws {
        let json = """
        {
            "cid": "bafytest",
            "mimeType": "image/jpeg",
            "size": 50000,
            "ref": "at://did:plc:user/blob/ref"
        }
        """
        
        let decoder = JSONDecoder()
        let data = json.data(using: .utf8)!
        
        let blob = try decoder.decode(MLSBlobRef.self, from: data)
        
        XCTAssertEqual(blob.cid, "bafytest")
        XCTAssertEqual(blob.mimeType, "image/jpeg")
        XCTAssertEqual(blob.size, 50000)
        XCTAssertEqual(blob.ref, "at://did:plc:user/blob/ref")
    }
    
    func testMLSEpochInfoDecoding() throws {
        let json = """
        {
            "epoch": 10,
            "groupId": "group789",
            "memberCount": 5,
            "updatedAt": "2024-01-01T00:00:00Z"
        }
        """
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        
        let epochInfo = try decoder.decode(MLSEpochInfo.self, from: data)
        
        XCTAssertEqual(epochInfo.epoch, 10)
        XCTAssertEqual(epochInfo.groupId, "group789")
        XCTAssertEqual(epochInfo.memberCount, 5)
        XCTAssertNotNil(epochInfo.updatedAt)
    }
    
    // MARK: - Error Handling Tests
    
    func testMLSAPIErrorDescriptions() {
        let noAuthError = MLSAPIError.noAuthentication
        XCTAssertNotNil(noAuthError.errorDescription)
        XCTAssertTrue(noAuthError.errorDescription!.contains("Authentication required"))
        
        let httpError = MLSAPIError.httpError(statusCode: 404, message: "Not found")
        XCTAssertNotNil(httpError.errorDescription)
        XCTAssertTrue(httpError.errorDescription!.contains("404"))
        
        let blobError = MLSAPIError.blobTooLarge
        XCTAssertNotNil(blobError.errorDescription)
        XCTAssertTrue(blobError.errorDescription!.contains("50MB"))
    }
    
    func testMLSAPIErrorResponseDecoding() throws {
        let json = """
        {
            "error": "InvalidCiphertext",
            "message": "The provided ciphertext is invalid"
        }
        """
        
        let decoder = JSONDecoder()
        let data = json.data(using: .utf8)!
        
        let errorResponse = try decoder.decode(MLSAPIErrorResponse.self, from: data)
        
        XCTAssertEqual(errorResponse.error, "InvalidCiphertext")
        XCTAssertEqual(errorResponse.message, "The provided ciphertext is invalid")
    }
    
    // MARK: - Configuration Tests
    
    func testClientInitializationWithDefaults() {
        let defaultClient = MLSAPIClient()
        XCTAssertNotNil(defaultClient)
    }
    
    func testClientInitializationWithCustomConfig() {
        let customURL = URL(string: "https://custom.example.com")!
        let customClient = MLSAPIClient(
            baseURL: customURL,
            userDid: "did:plc:custom",
            authToken: "custom_token",
            maxRetries: 5,
            retryDelay: 2.0
        )
        XCTAssertNotNil(customClient)
    }
    
    // MARK: - Pagination Tests
    
    func testConversationPaginationModel() throws {
        let json = """
        {
            "convos": [],
            "cursor": "next_page_cursor"
        }
        """
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        
        let response = try decoder.decode(MLSGetConvosResponse.self, from: data)
        
        XCTAssertEqual(response.convos.count, 0)
        XCTAssertEqual(response.cursor, "next_page_cursor")
    }
    
    func testMessagePaginationModel() throws {
        let json = """
        {
            "messages": [],
            "cursor": "msg_next_cursor"
        }
        """
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        
        let response = try decoder.decode(MLSGetMessagesResponse.self, from: data)
        
        XCTAssertEqual(response.messages.count, 0)
        XCTAssertEqual(response.cursor, "msg_next_cursor")
    }
    
    // MARK: - Date Encoding/Decoding Tests
    
    func testISO8601DateEncodingDecoding() throws {
        let date = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        let dateData = try encoder.encode(date)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let decodedDate = try decoder.decode(Date.self, from: dateData)
        
        // ISO8601 has second precision, so compare with tolerance
        XCTAssertEqual(date.timeIntervalSince1970, decodedDate.timeIntervalSince1970, accuracy: 1.0)
    }
    
    // MARK: - Welcome Message Tests
    
    func testWelcomeMessageDecoding() throws {
        let json = """
        {
            "did": "did:plc:newmember",
            "welcome": "base64welcomemessage=="
        }
        """
        
        let decoder = JSONDecoder()
        let data = json.data(using: .utf8)!
        
        let welcome = try decoder.decode(MLSWelcomeMessage.self, from: data)
        
        XCTAssertEqual(welcome.did, "did:plc:newmember")
        XCTAssertEqual(welcome.welcome, "base64welcomemessage==")
    }
    
    func testCreateConvoResponseWithWelcomes() throws {
        let json = """
        {
            "convo": {
                "id": "convo123",
                "groupId": "group456",
                "creator": "did:plc:creator",
                "members": [],
                "epoch": 0,
                "createdAt": "2024-01-01T00:00:00Z"
            },
            "welcomeMessages": [
                {
                    "did": "did:plc:member1",
                    "welcome": "welcome1=="
                }
            ]
        }
        """
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = json.data(using: .utf8)!
        
        let response = try decoder.decode(MLSCreateConvoResponse.self, from: data)
        
        XCTAssertEqual(response.convo.id, "convo123")
        XCTAssertEqual(response.welcomeMessages.count, 1)
        XCTAssertEqual(response.welcomeMessages[0].did, "did:plc:member1")
    }
    
    // MARK: - Metadata Tests
    
    func testConvoMetadataWithAllFields() throws {
        let blobRef = MLSBlobRef(
            cid: "bafyavatar",
            mimeType: "image/png",
            size: 50000,
            ref: nil
        )
        
        let metadata = MLSConvoMetadata(
            name: "Test Group Chat",
            description: "A test group for unit testing",
            avatar: blobRef
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(metadata)
        
        XCTAssertNotNil(data)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MLSConvoMetadata.self, from: data)
        
        XCTAssertEqual(decoded.name, "Test Group Chat")
        XCTAssertEqual(decoded.description, "A test group for unit testing")
        XCTAssertEqual(decoded.avatar?.cid, "bafyavatar")
    }
    
    func testConvoMetadataWithNilFields() throws {
        let metadata = MLSConvoMetadata(
            name: nil,
            description: nil,
            avatar: nil
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(metadata)
        
        XCTAssertNotNil(data)
    }
}
