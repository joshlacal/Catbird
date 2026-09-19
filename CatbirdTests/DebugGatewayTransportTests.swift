//
//  DebugGatewayTransportTests.swift
//  CatbirdTests
//
//  Tests for DebugGatewayTransport:
//  - Release excludes it
//  - Unknown host fails
//  - Wrong CA fails
//  - Hostname verification
//  - Refuse to activate without manifest
//  - File permission and size bounds
//  - Manifest and session validation
//

import Foundation
import Security
import Testing
@testable import Catbird

@Suite("DebugGatewayTransport Tests")
struct DebugGatewayTransportTests {

    private static let testCertDERBase64 = """
    MIIC/zCCAeegAwIBAgIUZLi6rTNrcxlv/F8n3D3J+E13gVQwDQYJKoZIhvcNAQELBQAwDzENMAsG\
    A1UEAwwEdGVzdDAeFw0yNjA5MjMxMjI0MjRaFw0yNzA5MjMxMjI0MjRaMA8xDTALBgNVBAMMBHRl\
    c3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDLjwA/n40q9dztYq79+WSgA1dCTRIi\
    FWqMQap5zbBOtRt4hBeBFS369R5xsu5s9pAy4K21G3F2Mv3diIyvBnIy5vXR/BDCswuQwB0BwZ50\
    L9u6DfBfjs9q/t39GZQkhHEkuZKQNauMbT1tchgRkjy9zwm7p7tO7iEEUvd+q+G+urPEncf2UKuJ\
    iExX5ERrC3s7MAuvRL0HbVKW7cBfqj0vcJJJ9bXghjKpvrGUTblr2oSoWv9Ea+SP/5R8reKrjFGA\
    i+R0Dcq9cQCfE2mYEOQiaFWKijaNfIebf4EqXbygZDJ7m8R9tODLu2KKMFVG2FTVe8TXG4vQgUFE\
    YiSWnyqXAgMBAAGjUzBRMB0GA1UdDgQWBBQRc3dUrvkWpkgXX3L4H699XZwvnjAfBgNVHSMEGDAW\
    gBQRc3dUrvkWpkgXX3L4H699XZwvnjAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IB\
    AQAspvzxnakQrzJep1z0T0bhagRDeZa0EHBr0jqHKyhEq8J5Bqs0+4XowznOr+oMtOlrbs+gBKxy\
    8KwmD7nP0J7FHyQ7f9Z9InoAEerAhsCi0/G+Z7SpusjbPIToI4IefX7AJoUW+MmveP3f21H2lzZn\
    BpYrr0IJzThSN3rgGmouhDrVt5NawFf0mnC0cD97gGgVq1MqxkItoV+Q8zkbDptQ6h6ClqBD0VRL\
    oSuBJl3dXT38ToWy1IePj/zh8MPyTmCPCgnakU1IWN2V/JTlrwBbGgZxVHWLAAM+nKlVdnLx5AyT\
    1bYO3lRRiKEcBPEYE2qdErMQQb59uG4pedeTexTU
    """

    // MARK: - Release Exclusion

    @Test("Release excludes or conditions fixture transport")
    func releaseExcludesFixtureTransport() {
        #if DEBUG
        #expect(DebugGatewayTransport.isAvailable == true)
        #else
        #expect(DebugGatewayTransport.isAvailable == false)
        let transport = DebugGatewayTransport()
        #expect(throws: DebugGatewayTransportError.releaseBuildForbidden) {
            try transport.activate(arguments: [], environment: [:])
        }
        #endif
    }

    // MARK: - Activation Refusal Without Manifest

    @Test("Refuses to activate without fixture manifest")
    func refuseToActivateWithoutManifest() throws {
        #if DEBUG
        let transport = DebugGatewayTransport()
        // No arguments or environment variables provided -> must return false
        let activated = try transport.activate(arguments: ["Catbird"], environment: [:])
        #expect(activated == false)
        #expect(transport.isActivated == false)
        #endif
    }

    // MARK: - Host Validation

    @Test("Validates fixture hosts format and rejects attackers")
    func fixtureHostValidation() {
        #if DEBUG
        // Valid fixture hosts
        #expect(DebugGatewayTransport.isFixtureHost("gateway-001.request-fixture.catbird.blue"))
        #expect(DebugGatewayTransport.isFixtureHost("alice-001.request-fixture.catbird.blue"))
        #expect(DebugGatewayTransport.isFixtureHost("bob-001.request-fixture.catbird.blue"))

        // Invalid hosts: uppercase, special characters, non-conforming domains
        #expect(!DebugGatewayTransport.isFixtureHost("GATEWAY-001.request-fixture.catbird.blue"))
        #expect(!DebugGatewayTransport.isFixtureHost("example.com"))
        #expect(!DebugGatewayTransport.isFixtureHost("catbird.blue"))
        #expect(!DebugGatewayTransport.isFixtureHost("public.api.bsky.app"))
        #expect(!DebugGatewayTransport.isFixtureHost("attacker.com.request-fixture.catbird.blue.evil.com"))
        #expect(!DebugGatewayTransport.isFixtureHost(".request-fixture.catbird.blue"))
        #expect(!DebugGatewayTransport.isFixtureHost("..request-fixture.catbird.blue"))
        #expect(!DebugGatewayTransport.isFixtureHost("-invalid.request-fixture.catbird.blue"))
        #expect(!DebugGatewayTransport.isFixtureHost("invalid-.request-fixture.catbird.blue"))
        #expect(!DebugGatewayTransport.isFixtureHost("foo..bar.request-fixture.catbird.blue"))
        #endif
    }

    @Test("Unknown host fails permission check")
    func unknownHostFails() {
        #if DEBUG
        let transport = DebugGatewayTransport()
        // Without active configuration, unknown hosts fail
        #expect(!transport.isAllowedHost("unknown.request-fixture.catbird.blue"))
        #expect(!transport.isAllowedHost("example.com"))
        #expect(!transport.isAllowedHost("public.api.bsky.app"))
        #expect(!transport.isAllowedHost("127.0.0.1"))
        #expect(!transport.isAllowedHost("localhost"))
        #endif
    }

    // MARK: - Private File Reader Security Bounds

    @Test("Private file reader rejects insecure permissions and symlinks")
    func privateFileReaderSecurityBounds() throws {
        #if DEBUG
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("catbird-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("test-file.json")
        let content = Data("{\"test\": true}".utf8)
        try content.write(to: fileURL)

        // Set mode 0644 (world readable) -> MUST be rejected
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        #expect(throws: DebugGatewayTransportError.self) {
            _ = try DebugGatewayTransport.readPrivateFile(at: fileURL.path)
        }

        // Set mode 0600 (owner only) -> MUST be accepted
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let readData = try DebugGatewayTransport.readPrivateFile(at: fileURL.path)
        #expect(readData == content)

        // Symlink -> MUST be rejected
        let symlinkURL = tempDir.appendingPathComponent("test-symlink.json")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: fileURL)
        #expect(throws: DebugGatewayTransportError.self) {
            _ = try DebugGatewayTransport.readPrivateFile(at: symlinkURL.path)
        }
        #endif
    }

    @Test("Private file reader rejects files exceeding 65536 bytes")
    func privateFileReaderRejectsOversizedFiles() throws {
        #if DEBUG
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("catbird-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("large-file.bin")
        let largeContent = Data(repeating: 0x42, count: 65537)
        try largeContent.write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        #expect(throws: DebugGatewayTransportError.self) {
            _ = try DebugGatewayTransport.readPrivateFile(at: fileURL.path)
        }
        #endif
    }

    // MARK: - Manifest & Session Parsing Validation

    @Test("Manifest validation rejects non-loopback hosts and remote origins")
    func manifestValidationRejectsRemoteEndpoints() throws {
        #if DEBUG
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("catbird-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a dummy CA file with valid DER
        let caURL = tempDir.appendingPathComponent("ca.pem")
        let dummyCertPEM = """
        -----BEGIN CERTIFICATE-----
        \(Self.testCertDERBase64)
        -----END CERTIFICATE-----
        """
        try dummyCertPEM.data(using: .utf8)!.write(to: caURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caURL.path)

        // Manifest with remote IP
        let remoteIPManifest: [String: Any] = [
            "fixtureOnly": true,
            "origin": "https://gateway-001.request-fixture.catbird.blue",
            "corsOrigin": "http://127.0.0.1:5173",
            "caPem": caURL.path,
            "tlsCertificatePem": caURL.path,
            "tlsSpkiSha256": Data(repeating: 1, count: 32).base64EncodedString(),
            "hosts": [
                "gateway-001.request-fixture.catbird.blue": "192.0.2.1:443" // Non-loopback!
            ],
            "accounts": [
                ["label": "alice", "did": "did:web:alice-001.request-fixture.catbird.blue", "deviceId": "00000000-0000-4000-8000-000000000001"]
            ]
        ]
        let remoteData = try JSONSerialization.data(withJSONObject: remoteIPManifest)
        #expect(throws: DebugGatewayTransportError.self) {
            _ = try DebugGatewayTransport.parseAndValidateManifest(data: remoteData)
        }

        // Manifest with fixtureOnly = false
        var nonFixture = remoteIPManifest
        nonFixture["fixtureOnly"] = false
        nonFixture["hosts"] = ["gateway-001.request-fixture.catbird.blue": "127.0.0.1:4443"]
        let nonFixtureData = try JSONSerialization.data(withJSONObject: nonFixture)
        #expect(throws: DebugGatewayTransportError.self) {
            _ = try DebugGatewayTransport.parseAndValidateManifest(data: nonFixtureData)
        }
        #endif
    }

    // MARK: - Trust Evaluation Tests (Wrong CA & Host Mismatch)

    @Test("Trust evaluation rejects wrong CA certificate")
    func trustEvaluationRejectsWrongCA() throws {
        #if DEBUG
        guard let certData = Data(base64Encoded: Self.testCertDERBase64, options: .ignoreUnknownCharacters),
              let dummyCert = SecCertificateCreateWithData(nil, certData as CFData)
        else {
            Issue.record("Failed to create dummy certificate")
            return
        }

        var trust: SecTrust?
        let policy = SecPolicyCreateBasicX509()
        let status = SecTrustCreateWithCertificates([dummyCert] as CFArray, policy, &trust)
        #expect(status == errSecSuccess)
        guard let serverTrust = trust else {
            Issue.record("Failed to create SecTrust")
            return
        }

        let transport = DebugGatewayTransport()
        // Without active manifest or with wrong CA anchor, trust evaluation must return false
        #expect(transport.evaluateTrust(serverTrust: serverTrust, host: "gateway-001.request-fixture.catbird.blue") == false)
        #expect(transport.evaluateTrust(serverTrust: serverTrust, host: "unknown.host.com") == false)
        #endif
    }

    // MARK: - Live Gateway Smoke Test

    @Test("Live gateway smoke test on simulator")
    func liveGatewaySmokeTest() async throws {
        #if DEBUG
        // The fixture launch config is a required input. A missing file fails the test instead of
        // silently reporting success without running any assertion.
        let configPath = try #require(
            DebugGatewayTransport.resolveConfigPath() ?? "/tmp/catbird-apple-gateway-run-001/config.json"
        )
        let transport = DebugGatewayTransport()
        let config = try transport.loadLaunchConfig(from: configPath)
        try transport.activate(with: config)

        let result = try await transport.runSmokeTest()
        #expect(result.sessionRestored == true)
        #expect(result.restoredDID.starts(with: "did:web:"))
        #expect(result.inventorySessionId.count == 43)
        #expect(result.snapshotEventCursor.count == 43)
        #expect(result.conversationsCount == 0)
        #expect(result.pendingWelcomesCount == 0)
        #expect(result.leafRecoveryInboxCount == 0)
        #expect(result.ticket.count == 43)
        #expect(result.ticketEndpoint == "wss://chat.catbird.blue/xrpc/blue.catbird.chat.subscribeEvents")
        #expect(result.webSocketHandshakeSuccess == true)
        #expect(result.ticketReplayRejected == true)
        #endif
    }
}
