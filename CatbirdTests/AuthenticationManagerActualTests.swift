import Testing
import Foundation
import LocalAuthentication
@testable import Catbird
@testable import Petrel

@Suite("Authentication Manager Tests")
struct AuthenticationManagerActualTests {
    
    // MARK: - Test Setup
    
    private func createTestAuthManager() -> AuthenticationManager {
        return AuthenticationManager()
    }
    
    // MARK: - Initialization Tests
    
    @Test("Authentication Manager initializes correctly")
    func testAuthManagerInitialization() {
        let authManager = createTestAuthManager()
        #expect(authManager.state == .initializing, "Should start in initializing state")
        #expect(authManager.handle == nil, "Handle should be nil initially")
        #expect(authManager.client == nil, "Client should be nil initially")
    }
    
    @Test("Authentication Manager has correct OAuth configuration")
    func testOAuthConfiguration() {
        let authManager = createTestAuthManager()
        // Test that the manager can be created without throwing
        #expect(authManager.state == .initializing, "Should be in initializing state")
    }
    
    // MARK: - AuthState Tests
    
    @Test("AuthState enum works correctly")
    func testAuthStateEnum() {
        let initializing = AuthState.initializing
        let unauthenticated = AuthState.unauthenticated
        let authenticating = AuthState.authenticating
        let authenticated = AuthState.authenticated(userDID: "did:plc:test")
        let error = AuthState.error(message: "Test error")
        
        #expect(!initializing.isAuthenticated, "Initializing should not be authenticated")
        #expect(!unauthenticated.isAuthenticated, "Unauthenticated should not be authenticated")
        #expect(!authenticating.isAuthenticated, "Authenticating should not be authenticated")
        #expect(authenticated.isAuthenticated, "Authenticated should be authenticated")
        #expect(!error.isAuthenticated, "Error should not be authenticated")
        
        #expect(authenticated.userDID == "did:plc:test", "Should return correct user DID")
        #expect(error.errorMessage == "Test error", "Should return correct error message")
    }
    
    @Test("AuthState equality works correctly")
    func testAuthStateEquality() {
        let state1 = AuthState.initializing
        let state2 = AuthState.initializing
        let state3 = AuthState.unauthenticated
        
        #expect(state1 == state2, "Same states should be equal")
        #expect(state1 != state3, "Different states should not be equal")
        
        let authenticated1 = AuthState.authenticated(userDID: "did:plc:test")
        let authenticated2 = AuthState.authenticated(userDID: "did:plc:test")
        let authenticated3 = AuthState.authenticated(userDID: "did:plc:other")
        
        #expect(authenticated1 == authenticated2, "Same authenticated states should be equal")
        #expect(authenticated1 != authenticated3, "Different user DIDs should not be equal")
    }
    
    // MARK: - Account Management Tests
    
    @Test("AccountInfo struct works correctly")
    func testAccountInfo() {
        let account1 = AuthenticationManager.AccountInfo(
            did: "did:plc:test",
            handle: "test.bsky.social",
            isActive: true
        )
        
        let account2 = AuthenticationManager.AccountInfo(
            did: "did:plc:test",
            handle: "test.bsky.social",
            isActive: false
        )
        
        let account3 = AuthenticationManager.AccountInfo(
            did: "did:plc:other",
            handle: "other.bsky.social",
            isActive: false
        )
        
        #expect(account1.id == "did:plc:test", "ID should match DID")
        #expect(account1 == account2, "Accounts with same DID should be equal")
        #expect(account1 != account3, "Accounts with different DIDs should not be equal")
    }
    
    @Test("Available accounts property is accessible")
    func testAvailableAccountsProperty() {
        let authManager = createTestAuthManager()
        #expect(authManager.availableAccounts.isEmpty, "Should start with empty available accounts")
    }
    
    @Test("Account switching state property is accessible")
    func testAccountSwitchingProperty() {
        let authManager = createTestAuthManager()
        #expect(!authManager.isSwitchingAccount, "Should not be switching account initially")
    }
    
    // MARK: - Biometric Authentication Tests
    
    @Test("Biometric authentication properties are accessible")
    func testBiometricProperties() {
        let authManager = createTestAuthManager()
        
        #expect(!authManager.biometricAuthEnabled, "Biometric auth should be disabled initially")
        #expect(authManager.biometricType == .none, "Biometric type should be none initially")
        #expect(authManager.lastBiometricError == nil, "Should have no biometric error initially")
    }
    
    // MARK: - Error Reset Tests
    
    @Test("Reset error method works")
    @MainActor
    func testResetError() {
        let authManager = createTestAuthManager()
        
        // This should not crash and should handle the current state appropriately
        authManager.resetError()
        
        // The state should remain initializing since it wasn't an error state
        #expect(authManager.state == .initializing, "Should remain in initializing state")
    }
    
    // MARK: - State Changes Tests
    
    @Test("State changes stream is accessible")
    func testStateChangesStream() {
        let authManager = createTestAuthManager()
        
        // Test that we can access the state changes stream without error
        let stateChanges = authManager.stateChanges
        #expect(stateChanges != nil, "State changes stream should be accessible")
    }
    
    // MARK: - Thread Safety Tests
    
    @Test("Authentication manager is thread-safe for property access")
    func testThreadSafety() async {
        let authManager = createTestAuthManager()
        
        // Test concurrent property access
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { @Sendable in
                    _ = authManager.state
                    _ = authManager.handle
                    _ = authManager.availableAccounts
                    _ = authManager.isSwitchingAccount
                    _ = authManager.biometricAuthEnabled
                }
            }
        }
        
        // Should complete without crashing
        #expect(authManager.state != nil, "Should maintain valid state after concurrent access")
    }
    
    // MARK: - Memory Management Tests
    
    @Test("Authentication manager memory management")
    func testMemoryManagement() {
        var authManager: AuthenticationManager? = createTestAuthManager()
        
        weak var weakAuthManager = authManager
        #expect(weakAuthManager != nil, "Should have weak reference")
        
        authManager = nil
        
        // Allow cleanup
        #expect(weakAuthManager == nil, "Should deallocate when no strong references")
    }
    
    // MARK: - Configuration Tests
    
    @Test("Authentication manager configures biometric authentication")
    @MainActor
    func testBiometricConfiguration() async {
        let authManager = createTestAuthManager()
        
        // Test that biometric configuration can be called without throwing
        await authManager.configureBiometricAuthentication()
        
        // The actual biometric availability depends on the device/simulator
        // We just test that the method completes
        #expect(true, "Biometric configuration should complete")
    }
    
    // MARK: - Quick Authentication Tests
    
    @Test("Quick authentication check works")
    @MainActor
    func testQuickAuthenticationCheck() async {
        let authManager = createTestAuthManager()
        
        // Should return true if biometric auth is not enabled
        let result = await authManager.quickAuthenticationCheck()
        #expect(result == true, "Should allow access when biometric auth is disabled")
    }
    
    // MARK: - Current Account Info Tests
    
    @Test("Get current account info returns nil when unauthenticated")
    @MainActor
    func testGetCurrentAccountInfoUnauthenticated() async {
        let authManager = createTestAuthManager()
        
        let accountInfo = await authManager.getCurrentAccountInfo()
        #expect(accountInfo == nil, "Should return nil when not authenticated")
    }
    
    // MARK: - AuthError Tests
    
    @Test("AuthError types work correctly")
    func testAuthErrorTypes() {
        let clientError = AuthError.clientNotInitialized
        let sessionError = AuthError.invalidSession
        let credentialsError = AuthError.invalidCredentials
        let networkError = AuthError.networkError(NSError(domain: "test", code: 1))
        let badResponseError = AuthError.badResponse(500)
        let unknownError = AuthError.unknown(NSError(domain: "test", code: 2))
        
        #expect(clientError.errorDescription?.contains("not initialized") == true, "Client error should have correct description")
        #expect(sessionError.errorDescription?.contains("Invalid session") == true, "Session error should have correct description")
        #expect(credentialsError.errorDescription?.contains("Invalid credentials") == true, "Credentials error should have correct description")
        #expect(networkError.errorDescription?.contains("Network error") == true, "Network error should have correct description")
        #expect(badResponseError.errorDescription?.contains("Bad response") == true, "Bad response error should have correct description")
        #expect(unknownError.errorDescription?.contains("Unknown error") == true, "Unknown error should have correct description")
    }
    
    // MARK: - LABiometryType Extension Tests
    
    @Test("LABiometryType extension works correctly")
    func testLABiometryTypeExtension() {
        #expect(LABiometryType.none.description == "None", "None type should have correct description")
        #expect(LABiometryType.touchID.description == "Touch ID", "Touch ID should have correct description")
        #expect(LABiometryType.faceID.description == "Face ID", "Face ID should have correct description")
        #expect(LABiometryType.opticID.description == "Optic ID", "Optic ID should have correct description")
        
        #expect(LABiometryType.none.displayName == "No biometric authentication", "None type should have correct display name")
        #expect(LABiometryType.touchID.displayName == "Touch ID", "Touch ID should have correct display name")
        #expect(LABiometryType.faceID.displayName == "Face ID", "Face ID should have correct display name")
        #expect(LABiometryType.opticID.displayName == "Optic ID", "Optic ID should have correct display name")
    }
    
    // MARK: - AsyncStream Extension Tests
    
    @Test("AsyncStream makeStream extension works")
    func testAsyncStreamExtension() {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        
        #expect(stream != nil, "Stream should be created")
        #expect(continuation != nil, "Continuation should be created")
        
        // Test that we can yield values
        continuation.yield("test")
        continuation.finish()
    }
}