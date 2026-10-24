//
//  DebugGatewayTransport.swift
//  Catbird
//
//  Debug-only local gateway transport for live encrypted-requests qualification.
//  Excluded from Release configurations by compile condition (#if DEBUG).
//

#if DEBUG && canImport(Network) && canImport(Security)
import CatbirdMLSCore
import CryptoKit
import Foundation
import Network
import Petrel
import Security

public enum DebugGatewayTransportError: Error, Equatable, LocalizedError {
    case releaseBuildForbidden
    case missingConfiguration
    case invalidConfiguration(String)
    case unreadableFile(String)
    case insecureFilePermissions(String)
    case fileTooLarge(String)
    case invalidManifest(String)
    case invalidCertificate(String)
    case invalidSessions(String)
    case profileError(String)
    case unknownHost(String)
    case untrustedCA
    case sessionRestorationFailed(String)
    case inventoryFailed(String)
    case ticketFailed(String)
    case webSocketFailed(String)

    public var errorDescription: String? {
        switch self {
        case .releaseBuildForbidden:
            return "DebugGatewayTransport is forbidden in Release builds"
        case .missingConfiguration:
            return "Missing fixture launch configuration (launch argument or CATBIRD_RUNTIME_FIXTURE_CONFIG)"
        case let .invalidConfiguration(msg):
            return "Invalid fixture configuration: \(msg)"
        case let .unreadableFile(msg):
            return "Unreadable fixture file: \(msg)"
        case let .insecureFilePermissions(msg):
            return "Insecure fixture file permissions: \(msg)"
        case let .fileTooLarge(msg):
            return "Fixture file exceeds size limit: \(msg)"
        case let .invalidManifest(msg):
            return "Invalid fixture manifest: \(msg)"
        case let .invalidCertificate(msg):
            return "Invalid fixture certificate: \(msg)"
        case let .invalidSessions(msg):
            return "Invalid fixture sessions: \(msg)"
        case let .profileError(msg):
            return "Profile error: \(msg)"
        case let .unknownHost(host):
            return "Unknown host rejected by fixture transport: \(host)"
        case .untrustedCA:
            return "Server trust evaluation failed against fixture CA"
        case let .sessionRestorationFailed(msg):
            return "Session restoration failed: \(msg)"
        case let .inventoryFailed(msg):
            return "Inventory query failed: \(msg)"
        case let .ticketFailed(msg):
            return "Subscription ticket failed: \(msg)"
        case let .webSocketFailed(msg):
            return "WebSocket connection failed: \(msg)"
        }
    }
}

public final class DebugGatewayTransport: @unchecked Sendable {
    public static let shared = DebugGatewayTransport()
    public static var isAvailable: Bool { true }

    public struct LaunchConfig: Sendable, Equatable {
        public let manifestPath: String
        public let sessionsPath: String
        public let label: String
        public let profilePath: String
        public let keychainNamespace: String

        public init(manifestPath: String, sessionsPath: String, label: String, profilePath: String, keychainNamespace: String) {
            self.manifestPath = manifestPath
            self.sessionsPath = sessionsPath
            self.label = label
            self.profilePath = profilePath
            self.keychainNamespace = keychainNamespace
        }
    }

    public struct AccountInfo: Sendable, Equatable {
        public let label: String
        public let did: String
        public let deviceId: String
        public let session: String?

        public init(label: String, did: String, deviceId: String, session: String? = nil) {
            self.label = label
            self.did = did
            self.deviceId = deviceId
            self.session = session
        }
    }

    public struct ManifestInfo: Sendable {
        public let origin: URL
        public let hosts: [String: String]
        public let allowedHosts: Set<String>
        public let accounts: [AccountInfo]
        public let caCertificate: SecCertificate
        public let caCertificateDER: Data
        public let caPemPath: String
        public let tlsCertificatePemPath: String
        public let tlsSpkiSha256: String
    }

    public struct SmokeTestResult: Sendable {
        public let sessionRestored: Bool
        public let restoredDID: String
        public let restoredHandle: String
        public let deviceSeeded: Bool
        public let inventorySessionId: String
        public let snapshotEventCursor: String
        public let inventoryScopeVersions: [String]
        public let conversationsCount: Int
        public let pendingWelcomesCount: Int
        public let leafRecoveryInboxCount: Int
        public let ticket: String
        public let ticketEndpoint: String
        public let ticketScopeVersions: [String]
        public let webSocketHandshakeStatus: Int
        public let webSocketRequestHadOrigin: Bool
        public let ticketReplayStatus: Int
    }

    /// The inventory scope every smoke request presents; the ticket must be minted under the same scope.
    static let smokeProtocolVersions = ["1", "2"]

    private let lock = NSLock()
    public private(set) var activeConfig: LaunchConfig?
    public private(set) var activeManifest: ManifestInfo?
    public private(set) var activeAccount: AccountInfo?
    public private(set) var underlyingTransport: DebugFixtureTransport?
    public private(set) var isActivated = false

    public init() {}

    // MARK: - Activation

    /// Attempts to activate the fixture transport from process arguments or environment variables.
    /// Returns true if activated, or false if no fixture configuration was provided.
    @discardableResult
    public func activate(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Bool {
        guard let configPath = Self.resolveConfigPath(arguments: arguments, environment: environment) else {
            return false
        }
        let config = try loadLaunchConfig(from: configPath)
        try activate(with: config)
        return true
    }

    public func activate(with config: LaunchConfig) throws {
        try lock.withLock {
            guard !isActivated else { return }

            // 1. Read and validate manifest
            let manifestData = try Self.readPrivateFile(at: config.manifestPath)
            let manifestInfo = try Self.parseAndValidateManifest(data: manifestData)

            // 2. Read and validate sessions
            let sessionsData = try Self.readPrivateFile(at: config.sessionsPath)
            let account = try Self.parseAndValidateSessions(data: sessionsData, label: config.label, manifest: manifestInfo)

            // 3. Validate profile directory and marker
            try Self.validateProfileDirectory(config: config, manifest: manifestInfo, account: account)

            // 4. Install underlying Petrel transport (HTTP CONNECT tunnel)
            let transport: DebugFixtureTransport
            if let existing = DebugFixtureTransport.current {
                transport = existing
            } else {
                var installedTransport: DebugFixtureTransport?
                var installError: Error?
                let sema = DispatchSemaphore(value: 0)
                Task {
                    do {
                        installedTransport = try await DebugFixtureTransport.install(manifest: manifestData, certificateDER: manifestInfo.caCertificateDER)
                    } catch {
                        installError = error
                    }
                    sema.signal()
                }
                sema.wait()
                if let installError {
                    throw installError
                }
                guard let t = installedTransport ?? DebugFixtureTransport.current else {
                    throw DebugGatewayTransportError.invalidConfiguration("DebugFixtureTransport installation failed")
                }
                transport = t
            }

            self.activeConfig = config
            self.activeManifest = manifestInfo
            self.activeAccount = account
            self.underlyingTransport = transport
            MLSStoragePaths.setBaseDirectoryOverride(URL(fileURLWithPath: config.profilePath))
            self.isActivated = true
        }
    }

    // MARK: - Configuration Path Resolution

    public static func resolveConfigPath(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        FixtureLaunch.resolveConfigPath(arguments: arguments, environment: environment)
    }

    // MARK: - Private File Reader

    public static func readPrivateFile(at path: String) throws -> Data {
        do {
            return try FixtureLaunch.readPrivateFile(at: path)
        } catch let error as FixtureLaunch.FileError {
            switch error {
            case let .unreadable(message): throw DebugGatewayTransportError.unreadableFile(message)
            case let .tooLarge(message): throw DebugGatewayTransportError.fileTooLarge(message)
            case let .insecurePermissions(message): throw DebugGatewayTransportError.insecureFilePermissions(message)
            case let .invalidConfiguration(message): throw DebugGatewayTransportError.invalidConfiguration(message)
            }
        }
    }

    // MARK: - Launch Config Loading

    public func loadLaunchConfig(from path: String) throws -> LaunchConfig {
        let data = try Self.readPrivateFile(at: path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DebugGatewayTransportError.invalidConfiguration("JSON root must be an object")
        }
        guard let manifestPath = json["manifest"] as? String, !manifestPath.isEmpty,
              let sessionsPath = json["sessions"] as? String, !sessionsPath.isEmpty,
              let label = json["label"] as? String, ["alice", "bob"].contains(label),
              let profilePath = json["profile"] as? String, !profilePath.isEmpty,
              let keychainNamespace = json["keychain_namespace"] as? String, !keychainNamespace.isEmpty
        else {
            throw DebugGatewayTransportError.invalidConfiguration("Missing required launch config fields")
        }
        return LaunchConfig(
            manifestPath: manifestPath,
            sessionsPath: sessionsPath,
            label: label,
            profilePath: profilePath,
            keychainNamespace: keychainNamespace
        )
    }

    // MARK: - Manifest Parser & Validator

    public static func parseAndValidateManifest(data: Data) throws -> ManifestInfo {
        guard data.count <= 16384 else {
            throw DebugGatewayTransportError.fileTooLarge("Manifest size exceeds 16384 bytes")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DebugGatewayTransportError.invalidManifest("Manifest root must be an object")
        }

        guard json["fixtureOnly"] as? Bool == true else {
            throw DebugGatewayTransportError.invalidManifest("fixtureOnly must be true")
        }

        guard let originStr = json["origin"] as? String,
              let origin = URL(string: originStr),
              origin.scheme == "https",
              let originHost = origin.host?.lowercased(),
              originStr == "https://\(originHost)",
              isFixtureHost(originHost),
              originHost.hasPrefix("gateway-")
        else {
            throw DebugGatewayTransportError.invalidManifest("Invalid fixture origin URL")
        }

        guard let caPemPath = json["caPem"] as? String, caPemPath.hasPrefix("/") else {
            throw DebugGatewayTransportError.invalidManifest("Invalid caPem path")
        }
        guard let tlsCertPath = json["tlsCertificatePem"] as? String, tlsCertPath.hasPrefix("/") else {
            throw DebugGatewayTransportError.invalidManifest("Invalid tlsCertificatePem path")
        }
        guard let spki = json["tlsSpkiSha256"] as? String,
              let spkiBytes = Data(base64Encoded: spki), spkiBytes.count == 32
        else {
            throw DebugGatewayTransportError.invalidManifest("Invalid tlsSpkiSha256")
        }

        // Read CA PEM and extract DER
        let caPemData = try readPrivateFile(at: caPemPath)
        let caDerData = try extractCertificateDER(from: caPemData)
        guard let caCert = SecCertificateCreateWithData(nil, caDerData as CFData) else {
            throw DebugGatewayTransportError.invalidCertificate("Failed to create SecCertificate from CA DER")
        }

        // Parse accounts
        guard let rawAccounts = json["accounts"] as? [[String: Any]], !rawAccounts.isEmpty, rawAccounts.count <= 2 else {
            throw DebugGatewayTransportError.invalidManifest("Manifest accounts must have 1 or 2 entries")
        }
        var accounts: [AccountInfo] = []
        var allowedAccountHosts = Set<String>()
        for row in rawAccounts {
            guard let label = row["label"] as? String, ["alice", "bob"].contains(label),
                  !accounts.contains(where: { $0.label == label }),
                  let did = row["did"] as? String, did.hasPrefix("did:web:"),
                  let deviceId = row["deviceId"] as? String,
                  UUID(uuidString: deviceId)?.uuidString.lowercased() == deviceId.lowercased()
            else {
                throw DebugGatewayTransportError.invalidManifest("Invalid account entry in manifest")
            }
            let accountHost = String(did.dropFirst("did:web:".count)).lowercased()
            guard isFixtureHost(accountHost), accountHost.hasPrefix(label + "-") else {
                throw DebugGatewayTransportError.invalidManifest("Invalid account DID host: \(accountHost)")
            }
            allowedAccountHosts.insert(accountHost)
            accounts.append(AccountInfo(label: label, did: did, deviceId: deviceId))
        }

        // Parse hosts map
        guard let rawHosts = json["hosts"] as? [String: String], !rawHosts.isEmpty else {
            throw DebugGatewayTransportError.invalidManifest("Missing or empty hosts map")
        }

        var hosts: [String: String] = [:]
        var ports = Set<UInt16>()
        for (hostKey, endpoint) in rawHosts {
            let hostLower = hostKey.lowercased()
            guard endpoint.hasPrefix("127.0.0.1:"),
                  let port = UInt16(endpoint.dropFirst("127.0.0.1:".count)),
                  port > 1023,
                  endpoint == "127.0.0.1:\(port)"
            else {
                throw DebugGatewayTransportError.invalidManifest("Host \(hostKey) mapped to non-loopback endpoint: \(endpoint)")
            }
            ports.insert(port)
            hosts[hostLower] = endpoint
        }

        guard ports.count == 1 else {
            throw DebugGatewayTransportError.invalidManifest("All fixture hosts must map to the same TLS port")
        }

        // Client allowed hosts: exclude public.api.bsky.app!
        var allowedHosts = Set<String>()
        for host in hosts.keys {
            if host == "chat.catbird.blue" || (isFixtureHost(host) && host != "public.api.bsky.app") {
                allowedHosts.insert(host)
            }
        }
        guard allowedHosts.contains(originHost), allowedHosts.contains("chat.catbird.blue") else {
            throw DebugGatewayTransportError.invalidManifest("Allowed hosts must include origin and chat.catbird.blue")
        }

        return ManifestInfo(
            origin: origin,
            hosts: hosts,
            allowedHosts: allowedHosts,
            accounts: accounts,
            caCertificate: caCert,
            caCertificateDER: caDerData,
            caPemPath: caPemPath,
            tlsCertificatePemPath: tlsCertPath,
            tlsSpkiSha256: spki
        )
    }

    // MARK: - Certificate Parsing

    public static func extractCertificateDER(from pemData: Data) throws -> Data {
        guard let pemString = String(data: pemData, encoding: .utf8) ?? String(data: pemData, encoding: .ascii) else {
            throw DebugGatewayTransportError.invalidCertificate("Certificate PEM data is not valid text")
        }
        let lines = pemString.components(separatedBy: .newlines)
        var base64 = ""
        var inCert = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-----BEGIN CERTIFICATE-----") {
                inCert = true
                continue
            }
            if trimmed.contains("-----END CERTIFICATE-----") {
                inCert = false
                break
            }
            if inCert {
                base64 += trimmed
            }
        }
        guard let derData = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !derData.isEmpty else {
            throw DebugGatewayTransportError.invalidCertificate("Failed to base64-decode certificate DER from PEM")
        }
        return derData
    }

    // MARK: - Host Validation

    public static func isFixtureHost(_ host: String) -> Bool {
        guard host.count <= 253,
              host.hasSuffix(".request-fixture.catbird.blue"),
              host == host.lowercased(),
              !host.contains(".."),
              !host.hasPrefix("."),
              !host.hasPrefix("-")
        else {
            return false
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.utf8.allSatisfy({ (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 })
            else {
                return false
            }
        }
        return true
    }

    public func isAllowedHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "chat.catbird.blue" {
            return true
        }
        guard let manifest = activeManifest else { return false }
        return manifest.allowedHosts.contains(lower) && Self.isFixtureHost(lower)
    }

    // MARK: - Sessions Parser & Validator

    public static func parseAndValidateSessions(data: Data, label: String, manifest: ManifestInfo) throws -> AccountInfo {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = json["accounts"] as? [[String: Any]]
        else {
            throw DebugGatewayTransportError.invalidSessions("Sessions file root must contain accounts array")
        }
        guard let matching = accounts.first(where: { ($0["label"] as? String) == label }) else {
            throw DebugGatewayTransportError.invalidSessions("No session found for label: \(label)")
        }
        guard let did = matching["did"] as? String,
              let deviceId = matching["deviceId"] as? String,
              let session = matching["session"] as? String,
              !session.isEmpty, session.count <= 4096
        else {
            throw DebugGatewayTransportError.invalidSessions("Invalid session fields for label: \(label)")
        }

        // Verify account matches public manifest
        guard manifest.accounts.contains(where: { $0.label == label && $0.did == did && $0.deviceId == deviceId }) else {
            throw DebugGatewayTransportError.invalidSessions("Session account does not match public manifest account")
        }

        return AccountInfo(label: label, did: did, deviceId: deviceId, session: session)
    }

    // MARK: - Profile Directory Validation

    public static func validateProfileDirectory(config: LaunchConfig, manifest: ManifestInfo, account: AccountInfo) throws {
        let profilePath = config.profilePath
        guard profilePath.hasPrefix("/"), !profilePath.contains("..") else {
            throw DebugGatewayTransportError.profileError("Profile path must be absolute without parent references")
        }
        guard config.keychainNamespace.hasPrefix("blue.catbird.fixture.") || config.keychainNamespace.hasPrefix("blue.catbird.catmos.fixture.") else {
            throw DebugGatewayTransportError.profileError("Invalid keychain namespace prefix: \(config.keychainNamespace)")
        }

        let markerPath = (profilePath as NSString).appendingPathComponent("runtime-fixture.json")
        let markerPayload: [String: String] = [
            "origin": manifest.origin.absoluteString,
            "did": account.did,
            "deviceId": account.deviceId,
            "namespace": config.keychainNamespace
        ]
        let markerData = try JSONSerialization.data(withJSONObject: markerPayload, options: [.sortedKeys])

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: profilePath, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw DebugGatewayTransportError.profileError("Profile path is not a directory")
            }
            if FileManager.default.fileExists(atPath: markerPath) {
                let existingMarker = try readPrivateFile(at: markerPath)
                guard existingMarker == markerData else {
                    throw DebugGatewayTransportError.profileError("Existing profile marker belongs to another fixture identity")
                }
            }
        } else {
            try FileManager.default.createDirectory(atPath: profilePath, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
            FileManager.default.createFile(atPath: markerPath, contents: markerData, attributes: [
                .posixPermissions: 0o600
            ])
        }
    }

    // MARK: - Server Trust Evaluation

    public func evaluateTrust(serverTrust: SecTrust, host: String) -> Bool {
        let lowerHost = host.lowercased()
        guard isAllowedHost(lowerHost), let manifest = activeManifest else {
            return false
        }
        let policy = SecPolicyCreateSSL(true, lowerHost as CFString)
        guard SecTrustSetPolicies(serverTrust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(serverTrust, [manifest.caCertificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(serverTrust, true) == errSecSuccess
        else {
            return false
        }
        var error: CFError?
        return SecTrustEvaluateWithError(serverTrust, &error)
    }

    // MARK: - URLSession Creation

    /// Sessions come from Petrel's fixture transport: its CONNECT tunnel maps only manifest hosts to loopback
    /// and its delegate trusts only the fixture CA and refuses redirects, so this layer adds no second policy.
    public func makeSession() throws -> URLSession {
        guard let transport = underlyingTransport else {
            throw DebugGatewayTransportError.missingConfiguration
        }
        return try transport.makeSession()
    }

    // MARK: - Session Restoration

    public func restoreSession() async throws -> (did: String, handle: String) {
        guard let manifest = activeManifest, let account = activeAccount, let sessionToken = account.session else {
            throw DebugGatewayTransportError.missingConfiguration
        }

        let session = try makeSession()
        defer { session.finishTasksAndInvalidate() }

        let authURL = manifest.origin.appendingPathComponent("auth/session")
        var request = URLRequest(url: authURL)
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DebugGatewayTransportError.sessionRestorationFailed("Non-HTTP response")
        }
        guard httpResponse.statusCode == 200 else {
            throw DebugGatewayTransportError.sessionRestorationFailed("Expected 200 OK, got \(httpResponse.statusCode)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let did = json["did"] as? String,
              let handle = json["handle"] as? String
        else {
            throw DebugGatewayTransportError.sessionRestorationFailed("Invalid /auth/session JSON response")
        }

        guard did == account.did else {
            throw DebugGatewayTransportError.sessionRestorationFailed("DID mismatch: expected \(account.did), got \(did)")
        }

        // Store synthetic account into isolated keychain namespace
        if let config = activeConfig {
            try saveIsolatedKeychainEntry(service: config.keychainNamespace, account: "session_id", value: sessionToken)
            try saveIsolatedKeychainEntry(service: config.keychainNamespace, account: "user_did", value: did)
        }

        return (did: did, handle: handle)
    }

    // MARK: - Smoke Test Runner

    public func runSmokeTest() async throws -> SmokeTestResult {
        guard let manifest = activeManifest, let account = activeAccount, let sessionToken = account.session else {
            throw DebugGatewayTransportError.missingConfiguration
        }

        let session = try makeSession()
        defer { session.finishTasksAndInvalidate() }

        // Step 1: Session restore
        let (restoredDID, restoredHandle) = try await restoreSession()

        // Step 2: Preseed the reserved native device with this profile's own signing key (public half only).
        try await preseedReservedDevice(session: session, manifest: manifest, account: account, sessionToken: sessionToken)

        // Step 3: Three empty inventories under one session capability. A device event (such as the
        // preseed above) can re-materialize a fresh session between domains; the server then reports
        // InventorySessionMismatch on the first read of that session and the whole snapshot restarts.
        var snapshot: InventorySnapshot?
        for _ in 1...6 {
            snapshot = try await readInventorySnapshot(session: session, manifest: manifest, account: account, sessionToken: sessionToken)
            if snapshot != nil { break }
        }
        guard let snapshot else {
            throw DebugGatewayTransportError.inventoryFailed("Inventory session never stabilized across six attempts")
        }

        // Step 4: Subscription ticket minted under the same scope
        let ticketURL = manifest.origin.appendingPathComponent("xrpc/blue.catbird.chat.getSubscriptionTicket")
        var ticketReq = URLRequest(url: ticketURL)
        ticketReq.httpMethod = "POST"
        ticketReq.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        ticketReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let ticketPayload: [String: Any] = [
            "actorDeviceId": account.deviceId,
            "inventorySessionId": snapshot.sessionId,
            "eventCursor": snapshot.cursor,
            "supportedProtocolVersions": Self.smokeProtocolVersions
        ]
        ticketReq.httpBody = try JSONSerialization.data(withJSONObject: ticketPayload)
        let (ticketData, ticketResp) = try await session.data(for: ticketReq)
        let ticketStatus = (ticketResp as? HTTPURLResponse)?.statusCode ?? -1
        guard ticketStatus == 200,
              let ticketJSON = try JSONSerialization.jsonObject(with: ticketData) as? [String: Any],
              let ticket = ticketJSON["ticket"] as? String,
              let endpoint = ticketJSON["endpoint"] as? String,
              let ticketScope = (ticketJSON["inventoryScope"] as? [String: Any])?["supportedProtocolVersions"] as? [String]
        else {
            throw DebugGatewayTransportError.ticketFailed("getSubscriptionTicket returned \(ticketStatus): \(Self.bodyPreview(ticketData))")
        }

        // Step 5: Native WebSocket upgrade without an Origin header
        guard var wsComponents = URLComponents(string: endpoint) else {
            throw DebugGatewayTransportError.webSocketFailed("Invalid WebSocket endpoint URL: \(endpoint)")
        }
        wsComponents.queryItems = [
            URLQueryItem(name: "ticket", value: ticket),
            URLQueryItem(name: "cursor", value: snapshot.cursor)
        ]
        guard let wsURL = wsComponents.url else {
            throw DebugGatewayTransportError.webSocketFailed("Failed to construct WebSocket subscription URL")
        }
        let wsReq = URLRequest(url: wsURL)
        let handshake = await Self.upgrade(session: session, request: wsReq)
        guard handshake.status == 101, handshake.error == nil else {
            throw DebugGatewayTransportError.webSocketFailed(
                "Ticket upgrade returned \(handshake.status): \(handshake.error.map(String.init(describing:)) ?? "no error")"
            )
        }

        // Step 6: Replaying the consumed one-use ticket must be refused by the service.
        let replay = await Self.upgrade(session: session, request: wsReq)

        return SmokeTestResult(
            sessionRestored: true,
            restoredDID: restoredDID,
            restoredHandle: restoredHandle,
            deviceSeeded: true,
            inventorySessionId: snapshot.sessionId,
            snapshotEventCursor: snapshot.cursor,
            inventoryScopeVersions: snapshot.scopeVersions,
            conversationsCount: snapshot.counts[0],
            pendingWelcomesCount: snapshot.counts[1],
            leafRecoveryInboxCount: snapshot.counts[2],
            ticket: ticket,
            ticketEndpoint: endpoint,
            ticketScopeVersions: ticketScope,
            webSocketHandshakeStatus: handshake.status,
            webSocketRequestHadOrigin: wsReq.value(forHTTPHeaderField: "Origin") != nil,
            ticketReplayStatus: replay.status
        )
    }

    // MARK: - Smoke Test Steps

    private struct InventorySnapshot {
        let sessionId: String
        let cursor: String
        let scopeVersions: [String]
        let counts: [Int]
    }

    /// Documented native preseed: `POST /fixture/enroll` with the raw 32-byte Ed25519 public key. The private key
    /// stays in this profile's isolated keychain namespace and is reused, because the gateway rejects a
    /// different key for an already-seeded identity.
    private func preseedReservedDevice(session: URLSession, manifest: ManifestInfo, account: AccountInfo, sessionToken: String) async throws {
        guard let config = activeConfig else { throw DebugGatewayTransportError.missingConfiguration }
        let keyAccount = "fixture_signing_key.\(account.deviceId)"
        let signingKey: Curve25519.Signing.PrivateKey
        if let stored = try loadIsolatedKeychainEntry(service: config.keychainNamespace, account: keyAccount) {
            signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: stored)
        } else {
            signingKey = Curve25519.Signing.PrivateKey()
            try saveIsolatedKeychainEntry(service: config.keychainNamespace, account: keyAccount, data: signingKey.rawRepresentation)
        }

        var request = URLRequest(url: manifest.origin.appendingPathComponent("fixture/enroll"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_id": account.deviceId,
            "signature_public_key": signingKey.publicKey.rawRepresentation.base64EncodedString()
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["seeded"] as? Bool == true,
              json["deviceId"] as? String == account.deviceId,
              json["did"] as? String == account.did
        else {
            throw DebugGatewayTransportError.inventoryFailed("fixture/enroll returned \(status): \(Self.bodyPreview(data))")
        }
    }

    /// Reads all three inventory domains under one session. Returns nil when the session was re-materialized
    /// between domains so the caller restarts the snapshot; any other failure throws.
    private func readInventorySnapshot(session: URLSession, manifest: ManifestInfo, account: AccountInfo, sessionToken: String) async throws -> InventorySnapshot? {
        var sessionId: String?
        var cursor: String?
        var scopeVersions: [String] = []
        var counts: [Int] = []
        for nsid in ["getConversations", "getPendingWelcomes", "getLeafRecoveryInbox"] {
            var components = URLComponents(url: manifest.origin.appendingPathComponent("xrpc/blue.catbird.chat.\(nsid)"), resolvingAgainstBaseURL: false)
            var items = [URLQueryItem(name: "actorDeviceId", value: account.deviceId), URLQueryItem(name: "limit", value: "50")]
            if let sessionId { items.append(URLQueryItem(name: "inventorySessionId", value: sessionId)) }
            items += Self.smokeProtocolVersions.map { URLQueryItem(name: "supportedProtocolVersions", value: $0) }
            components?.queryItems = items
            guard let url = components?.url else {
                throw DebugGatewayTransportError.inventoryFailed("Failed to construct \(nsid) URL")
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if status == 400, sessionId != nil, json?["error"] as? String == "InventorySessionMismatch" {
                return nil
            }
            guard status == 200, let json,
                  let emittedSession = json["inventorySessionId"] as? String,
                  let emittedCursor = json["snapshotEventCursor"] as? String,
                  let items = json["items"] as? [Any],
                  json["hasMore"] as? Bool == false,
                  let versions = (json["inventoryScope"] as? [String: Any])?["supportedProtocolVersions"] as? [String]
            else {
                throw DebugGatewayTransportError.inventoryFailed("\(nsid) returned \(status): \(Self.bodyPreview(data))")
            }
            if let sessionId, let cursor {
                guard emittedSession == sessionId, emittedCursor == cursor, versions == scopeVersions else {
                    throw DebugGatewayTransportError.inventoryFailed("\(nsid) changed session, cursor, or scope within one snapshot")
                }
            } else {
                sessionId = emittedSession
                cursor = emittedCursor
                scopeVersions = versions
            }
            counts.append(items.count)
        }
        guard let sessionId, let cursor else { return nil }
        return InventorySnapshot(sessionId: sessionId, cursor: cursor, scopeVersions: scopeVersions, counts: counts)
    }

    /// Opens a WebSocket and reports the upgrade response status. A successful ping proves the upgraded
    /// connection is live; the task is closed immediately afterwards.
    private static func upgrade(session: URLSession, request: URLRequest) async -> (status: Int, error: Error?) {
        let task = session.webSocketTask(with: request)
        task.resume()
        let error: Error? = await withCheckedContinuation { continuation in
            task.sendPing { continuation.resume(returning: $0) }
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? -1
        task.cancel(with: .normalClosure, reason: nil)
        return (status, error)
    }

    private static func bodyPreview(_ data: Data) -> String {
        String(decoding: data.prefix(256), as: UTF8.self)
    }

    // MARK: - Isolated Keychain Storage Helper

    private func saveIsolatedKeychainEntry(service: String, account: String, value: String) throws {
        try saveIsolatedKeychainEntry(service: service, account: account, data: Data(value.utf8))
    }

    private func saveIsolatedKeychainEntry(service: String, account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = KeychainSecItem.delete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        let status = KeychainSecItem.add(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DebugGatewayTransportError.invalidConfiguration("keychain add failed with status \(status)")
        }
    }

    private func loadIsolatedKeychainEntry(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = KeychainSecItem.copyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw DebugGatewayTransportError.invalidConfiguration("keychain read failed with status \(status)")
        }
        return data
    }
}

#else

public enum DebugGatewayTransportError: Error, Equatable {
    case releaseBuildForbidden
}

public final class DebugGatewayTransport: @unchecked Sendable {
    public static let shared = DebugGatewayTransport()
    public static var isAvailable: Bool { false }

    public init() {}

    @discardableResult
    public func activate(
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> Bool {
        throw DebugGatewayTransportError.releaseBuildForbidden
    }
}

#endif
