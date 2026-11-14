//
//  BulkheadSealTests.swift
//  CatbirdTests
//
//  T7-APPLE Bulkhead, 120Hz MainActor Canary, & NSE/Host SQLite Cache Invalidation Gates:
//  - T7-BULKHEAD-FD: zero open file descriptors on <did_hash>.db* after prepareForBackground()
//  - T7-CANARY-120HZ: @MainActor scheduling jitter stays < 8.3ms under 64 concurrent FFI ops
//  - T7-NSE-DATAVERSION: NSE SQLite commit + Darwin wakeup invalidates open host connection cache
//

import CatbirdMLS
@testable import CatbirdMLSCore
import Darwin
import Foundation
import Security
import Testing
@testable import Catbird

private final class BulkheadKeychainBackend: KeychainBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: Data] = [:]

  private func key(from dict: [String: Any]) -> String {
    let service = (dict[kSecAttrService as String] as? String) ?? ""
    let account = (dict[kSecAttrAccount as String] as? String) ?? ""
    return "\(service)|\(account)"
  }

  func add(_ attributes: [String: Any]) -> OSStatus {
    lock.lock()
    defer { lock.unlock() }
    let k = key(from: attributes)
    if items[k] != nil { return errSecDuplicateItem }
    guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
    items[k] = data
    return errSecSuccess
  }

  func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
    lock.lock()
    defer { lock.unlock() }
    let k = key(from: query)
    guard let data = items[k] else { return (errSecItemNotFound, nil) }
    return (errSecSuccess, data as AnyObject)
  }

  func update(_ query: [String: Any], _ attributesToUpdate: [String: Any]) -> OSStatus {
    lock.lock()
    defer { lock.unlock() }
    let k = key(from: query)
    guard items[k] != nil else { return errSecItemNotFound }
    guard let data = attributesToUpdate[kSecValueData as String] as? Data else { return errSecParam }
    items[k] = data
    return errSecSuccess
  }

  func delete(_ query: [String: Any]) -> OSStatus {
    lock.lock()
    defer { lock.unlock() }
    let k = key(from: query)
    return items.removeValue(forKey: k) != nil ? errSecSuccess : errSecItemNotFound
  }
}

@Suite("T7-APPLE Bulkhead, 120Hz Canary, & NSE SQLite Cache Seal Tests", .serialized)
struct BulkheadSealTests {
  private func makeTempDir(prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func archiveTempDir(_ dir: URL) {
    let trash = FileManager.default.temporaryDirectory
      .appendingPathComponent("_trash-BulkheadSealTests", isDirectory: true)
    try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    try? FileManager.default.moveItem(
      at: dir,
      to: trash.appendingPathComponent("\(UUID().uuidString.lowercased())-\(dir.lastPathComponent)")
    )
  }

  /// Scans all process file descriptors (`0..<getdtablesize()`) via `fcntl(fd, F_GETPATH, ...)`
  /// and returns every open path referencing `<didHash>.db` (including `-wal`, `-shm`, `-journal`).
  private func openDatabaseFilePaths(matchingDidHash didHash: String) -> [String] {
    let maxFd = getdtablesize()
    let needle = "\(didHash).db"
    var matches: [String] = []
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    for fd in 0..<maxFd {
      buffer[0] = 0
      if fcntl(fd, F_GETPATH, &buffer) != -1 {
        let path = String(cString: buffer)
        if path.contains(needle) {
          matches.append(path)
        }
      }
    }
    return matches
  }

  @Test("T7-BULKHEAD-FD: prepareForBackground closes 100% of SQLite file descriptors (<did_hash>.db*) before 0xdead10cc suspension")
  func testBulkheadPrepareForBackgroundClosesAllSQLiteFileDescriptors() async throws {
    let network = NativeArchiveMockNetwork.shared
    network.reset()
    let tempRoot = try makeTempDir(prefix: "t7-bulkhead-fd")
    defer { archiveTempDir(tempRoot) }

    let accountDid = "did:plc:tsevenbulkheadfduseraaaa"
    let deviceId = "33333333-4444-4555-8666-777777777777"
    let conversationId = "44444444-5555-4666-8777-888888888888"
    let keystore = KeychainPlatformKeyStore(
      service: "blue.catbird.mls.t7fd.\(UUID().uuidString)",
      backend: BulkheadKeychainBackend()
    )
    let transport = PetrelPlatformTransport(
      homeDsEndpoint: URL(string: NativeArchiveMockNetwork.dsEndpoint),
      homeDsDid: NativeArchiveMockNetwork.dsDid,
      ownPdsEndpoint: URL(string: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)),
      actorDeviceId: deviceId,
      httpOverride: { req in network.handle(req) }
    )

    let coordinator = try await MLSClientCoordinator.open(
      config: CatbirdMlsClientConfig(
        storageRoot: tempRoot.path,
        accountDid: accountDid,
        deviceId: deviceId,
        homeDsDid: NativeArchiveMockNetwork.dsDid,
        homeDsEndpoint: NativeArchiveMockNetwork.dsEndpoint,
        pdsEndpoint: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)
      ),
      keystore: keystore,
      transport: transport
    )
    let didHash = await coordinator.accountDidHash

    _ = try await coordinator.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)
    _ = try await coordinator.createGroup(
      conversationId: conversationId,
      sequencerDid: NativeArchiveMockNetwork.dsDid,
      title: "FD Seal Group",
      description: nil
    )
    _ = try await coordinator.sendMessage(
      conversationId: conversationId,
      text: "Persist before background checkpoint"
    )

    // Sanity check: while active, the SQLCipher connection holds at least one open FD on <didHash>.db.
    let activeOpenPaths = openDatabaseFilePaths(matchingDidHash: didHash)
    #expect(!activeOpenPaths.isEmpty, "Active coordinator must hold an open SQLite FD prior to suspension")

    // Seal bulkhead for iOS background transition (.inactive / .background -> 0xdead10cc prevention).
    let report = try await coordinator.prepareForBackground()
    #expect(report.handleClosed)
    #expect( await MainActor.run { coordinator.isHandleClosed } )

    let postBackgroundOpenPaths = openDatabaseFilePaths(matchingDidHash: didHash)
    #expect(
      postBackgroundOpenPaths.isEmpty,
      "Expected 0 open SQLite FDs after prepareForBackground(), found: \(postBackgroundOpenPaths)"
    )

    // Resume from background and confirm encrypted state reopens cleanly.
    try await coordinator.resumeFromBackground()
    let persisted = try await coordinator.listMessages(conversationId: conversationId, limit: 10)
    #expect(persisted.count == 1)
    await coordinator.close()
  }

  @Test("T7-CANARY-120HZ: @MainActor scheduling jitter stays below 8.3ms (120Hz frame budget) during 64 concurrent coordinator ops")
  func testMainActorCanaryStaysUnder120HzFrameBudgetDuring64ConcurrentOps() async throws {
    let network = NativeArchiveMockNetwork.shared
    network.reset()
    let tempRoot = try makeTempDir(prefix: "t7-canary-120hz")
    defer { archiveTempDir(tempRoot) }

    let accountDid = "did:plc:tsevencanaryuseraaaaaaaa"
    let deviceId = "55555555-6666-4777-8888-999999999999"
    let conversationId = "66666666-7777-4888-8999-aaaaaaaaaaaa"
    let mainThreadLock = NSLock()
    nonisolated(unsafe) var sawMainThreadTransport = false

    let keystore = KeychainPlatformKeyStore(
      service: "blue.catbird.mls.t7canary.\(UUID().uuidString)",
      backend: BulkheadKeychainBackend()
    )
    let transport = PetrelPlatformTransport(
      homeDsEndpoint: URL(string: NativeArchiveMockNetwork.dsEndpoint),
      homeDsDid: NativeArchiveMockNetwork.dsDid,
      ownPdsEndpoint: URL(string: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)),
      actorDeviceId: deviceId,
      httpOverride: { req in
        if Thread.isMainThread {
          mainThreadLock.lock()
          sawMainThreadTransport = true
          mainThreadLock.unlock()
        }
        Thread.sleep(forTimeInterval: 0.006)
        return network.handle(req)
      }
    )

    let coordinator = try await MLSClientCoordinator.open(
      config: CatbirdMlsClientConfig(
        storageRoot: tempRoot.path,
        accountDid: accountDid,
        deviceId: deviceId,
        homeDsDid: NativeArchiveMockNetwork.dsDid,
        homeDsEndpoint: NativeArchiveMockNetwork.dsEndpoint,
        pdsEndpoint: NativeArchiveMockNetwork.pdsEndpoint(for: accountDid)
      ),
      keystore: keystore,
      transport: transport
    )

    _ = try await coordinator.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)
    _ = try await coordinator.createGroup(
      conversationId: conversationId,
      sequencerDid: NativeArchiveMockNetwork.dsDid,
      title: "120Hz Canary Group",
      description: nil
    )

    // Warm up @MainActor runloop before sampling 120Hz (8.33ms) dispatch latency.
    await MainActor.run {}

    final class CanaryStats: @unchecked Sendable {
      let lock = NSLock()
      var stop = false
      var samplesMicros: [Double] = []
    }
    let stats = CanaryStats()
    let probeQueue = DispatchQueue(label: "blue.catbird.mls.t7canary.probe", qos: .userInteractive)
    let canaryDone = DispatchSemaphore(value: 0)

    probeQueue.async {
      while true {
        stats.lock.lock()
        let shouldStop = stats.stop
        stats.lock.unlock()
        if shouldStop { break }

        let hopGate = DispatchSemaphore(value: 0)
        let enqueuedAt = ContinuousClock.now
        DispatchQueue.main.async {
          let elapsed = enqueuedAt.duration(to: ContinuousClock.now)
          let micros = Double(elapsed.components.seconds) * 1_000_000.0
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000.0
          stats.lock.lock()
          stats.samplesMicros.append(micros)
          stats.lock.unlock()
          hopGate.signal()
        }
        _ = hopGate.wait(timeout: .now() + 1.0)
        Thread.sleep(forTimeInterval: 0.004)
      }
      canaryDone.signal()
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for idx in 0..<64 {
        group.addTask {
          switch idx % 4 {
          case 0:
            _ = try await coordinator.sendMessage(
              conversationId: conversationId,
              messageId: String(format: "66666666-7777-4888-8999-%012x", idx),
              text: "canary load \(idx)"
            )
          case 1:
            _ = try await coordinator.listMessages(conversationId: conversationId, limit: 50)
          case 2:
            _ = try await coordinator.listConversations(limit: 25)
          default:
            _ = try await coordinator.labyrinthStatus()
          }
        }
      }
      try await group.waitForAll()
    }

    stats.lock.lock()
    stats.stop = true
    stats.lock.unlock()
    _ = canaryDone.wait(timeout: .now() + 2.0)

    let sortedMicros = stats.samplesMicros.sorted()
    #expect(!sortedMicros.isEmpty, "Canary must collect @MainActor scheduling samples during 64-op burst")
    let p95Index = min(sortedMicros.count - 1, Int(Double(sortedMicros.count) * 0.95))
    let p95Ms = sortedMicros[p95Index] / 1_000.0
    let medianMs = sortedMicros[sortedMicros.count / 2] / 1_000.0

    #expect(!sawMainThreadTransport, "FFI HTTP transport must never run on MainActor")
    #expect(
      p95Ms < 8.3,
      "Expected @MainActor p95 hop < 8.3ms (120Hz budget), got median=\(String(format: "%.3f", medianMs))ms p95=\(String(format: "%.3f", p95Ms))ms across \(sortedMicros.count) samples"
    )

    let persisted = try await coordinator.listMessages(conversationId: conversationId, limit: 100)
    #expect(persisted.count == 16)
    await coordinator.close()
  }

  @Test("T7-NSE-DATAVERSION: NSE SQLite commit while host coordinator is open wakes host and invalidates SQLite cache via PRAGMA data_version")
  func testNseCommitInvalidatesHostConnectionCacheViaDataVersionAndDarwinWake() async throws {
    let network = NativeArchiveMockNetwork.shared
    network.reset()
    let boundedSession = MLSBoundedURLSession(protocolClasses: [NativeArchiveMockURLProtocol.self])
    let tempRoot = try makeTempDir(prefix: "t7-nse-dataversion")
    defer {
      boundedSession.invalidateAndCancel()
      archiveTempDir(tempRoot)
    }

    let aliceRoot = tempRoot.appendingPathComponent("alice", isDirectory: true)
    let bobRoot = tempRoot.appendingPathComponent("bob", isDirectory: true)
    try FileManager.default.createDirectory(at: aliceRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bobRoot, withIntermediateDirectories: true)

    let aliceDid = "did:plc:tsevennsealiceaaaaaaaaaa"
    let bobDid = "did:plc:tsevennsebobbbbbbbbbbbbb"
    let aliceDeviceId = "77777777-8888-4999-8aaa-bbbbbbbbbbb1"
    let bobDeviceId = "77777777-8888-4999-8aaa-bbbbbbbbbbb2"
    let conversationId = "88888888-9999-4aaa-8bbb-cccccccccccc"
    let incomingMessageId = "99999999-aaaa-4bbb-8ccc-dddddddddddd"

    let aliceKeystore = KeychainPlatformKeyStore(
      service: "blue.catbird.mls.t7nse.alice.\(UUID().uuidString)",
      backend: BulkheadKeychainBackend()
    )
    let bobKeystore = KeychainPlatformKeyStore(
      service: "blue.catbird.mls.t7nse.bob.\(UUID().uuidString)",
      backend: BulkheadKeychainBackend()
    )

    let aliceTransport = PetrelPlatformTransport(
      homeDsEndpoint: URL(string: NativeArchiveMockNetwork.dsEndpoint),
      homeDsDid: NativeArchiveMockNetwork.dsDid,
      ownPdsEndpoint: URL(string: NativeArchiveMockNetwork.pdsEndpoint(for: aliceDid)),
      actorDeviceId: aliceDeviceId,
      boundedSession: boundedSession
    )
    let bobTransport = PetrelPlatformTransport(
      homeDsEndpoint: URL(string: NativeArchiveMockNetwork.dsEndpoint),
      homeDsDid: NativeArchiveMockNetwork.dsDid,
      ownPdsEndpoint: URL(string: NativeArchiveMockNetwork.pdsEndpoint(for: bobDid)),
      actorDeviceId: bobDeviceId,
      boundedSession: boundedSession
    )

    let alice = try await MLSClientCoordinator.open(
      config: CatbirdMlsClientConfig(
        storageRoot: aliceRoot.path,
        accountDid: aliceDid,
        deviceId: aliceDeviceId,
        homeDsDid: NativeArchiveMockNetwork.dsDid,
        homeDsEndpoint: NativeArchiveMockNetwork.dsEndpoint,
        pdsEndpoint: NativeArchiveMockNetwork.pdsEndpoint(for: aliceDid)
      ),
      keystore: aliceKeystore,
      transport: aliceTransport
    )
    let bob = try await MLSClientCoordinator.open(
      config: CatbirdMlsClientConfig(
        storageRoot: bobRoot.path,
        accountDid: bobDid,
        deviceId: bobDeviceId,
        homeDsDid: NativeArchiveMockNetwork.dsDid,
        homeDsEndpoint: NativeArchiveMockNetwork.dsEndpoint,
        pdsEndpoint: NativeArchiveMockNetwork.pdsEndpoint(for: bobDid)
      ),
      keystore: bobKeystore,
      transport: bobTransport
    )

    _ = try await bob.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)
    _ = try await alice.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)
    _ = try await alice.createGroup(
      conversationId: conversationId,
      sequencerDid: NativeArchiveMockNetwork.dsDid,
      memberDids: [bobDid],
      title: "NSE DataVersion Group",
      description: nil
    )
    _ = try await bob.sync()
    _ = try await alice.sync()
    _ = try await bob.sync()

    // Warm Bob's host SQLite connection & DataSource while keeping Bob's coordinator OPEN!
    let preRows = try await bob.listMessages(conversationId: conversationId, limit: 20)
    #expect(preRows.isEmpty)

    let bobDataSource = await MainActor.run {
      MLSConversationDataSource(
        conversationId: conversationId,
        currentUserDID: bobDid,
        appState: nil,
        mlsCoordinator: bob
      )
    }
    await bobDataSource.loadMessages()

    let bobDidHash = await bob.accountDidHash
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    try bobKeystore.storeCachedChatDpopToken(
      accountDidHash: bobDidHash,
      token: "valid-nse-dpop-token",
      expiresAtMs: nowMs + 120_000
    )

    let initialWakeups = await MainActor.run { bob.darwinWakeupCount }

    // Alice sends an encrypted MLS application message; Bob's host coordinator does NOT call sync().
    let sentRow = try await alice.sendMessage(
      conversationId: conversationId,
      messageId: incomingMessageId,
      text: "NSE cross-process commit visible immediately!"
    )

    // NSE opens its own independent SQLite connection on bobRoot, commits decrypted row, and posts Darwin wake.
    let preview = await MLSPushExtensionProcessor.processAsync(
      storageRoot: bobRoot,
      accountDidHash: bobDidHash,
      keystore: bobKeystore,
      transport: bobTransport,
      wake: PushWakePayload(
        kind: "application",
        conversationId: conversationId,
        generation: 0,
        entrySeq: sentRow.seq,
        messageId: incomingMessageId,
        recipientAccountHash: bobDidHash,
        fetchRequired: true,
        senderDid: aliceDid,
        inlineCiphertext: nil
      ),
      postDarwinNotification: true
    )

    #expect(preview.receiptVerified)
    #expect(!preview.fallbackGeneric)
    #expect(preview.body.contains("NSE cross-process commit visible immediately!"))

    // Wait briefly for Darwin notification delivery to open host coordinator + DataSource observation.
    for _ in 0..<40 {
      let wakeCount = await MainActor.run { bob.darwinWakeupCount }
      let dsCount = await MainActor.run { bobDataSource.messages.count }
      if wakeCount > initialWakeups && dsCount >= 1 {
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }

    let postWakeCount = await MainActor.run { bob.darwinWakeupCount }
    #expect(postWakeCount > initialWakeups, "Darwin wakeup must reach open host coordinator")

    // Host coordinator reads immediately from its already-open SQLite handle without sync() or reopen!
    let postRows = try await bob.listMessages(conversationId: conversationId, limit: 20)
    #expect(postRows.contains(where: { $0.messageId == incomingMessageId }))

    let dsMessages = await MainActor.run { bobDataSource.messages }
    #expect(dsMessages.contains(where: { $0.text.contains("NSE cross-process commit visible immediately!") }))

    await MainActor.run { bobDataSource.stopObserving() }
    await alice.close()
    await bob.close()
  }
}
