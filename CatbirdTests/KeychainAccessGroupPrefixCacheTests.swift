//
//  KeychainAccessGroupPrefixCacheTests.swift
//  CatbirdTests
//
//  KeychainAccessGroup.resolved(suffix:) runs on every auth keychain call on
//  iOS. The add/read/delete probe must run only on a cache miss, and a stored
//  prefix the keychain rejects must be replaced, not trusted.
//

import Foundation
import Testing
@testable import Catbird

@Suite("Keychain access group prefix cache")
struct KeychainAccessGroupPrefixCacheTests {
  private let key = "prefix"

  private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suiteName = "test.keychain-prefix.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try body(defaults)
  }

  private func makeStore(_ defaults: UserDefaults, plistPrefix: String? = nil) -> KeychainAccessGroup.TeamPrefixStore {
    KeychainAccessGroup.TeamPrefixStore(defaults: defaults, key: key, plistPrefix: plistPrefix)
  }

  @Test("The keychain is probed once per process")
  func probesOnce() throws {
    try withDefaults { defaults in
      let store = makeStore(defaults)
      var probes = 0
      let probe = { () -> String? in
        probes += 1
        return "ABCDE12345."
      }
      #expect(store.prefix(isEntitled: { _ in true }, probe: probe) == "ABCDE12345.")
      #expect(store.prefix(isEntitled: { _ in true }, probe: probe) == "ABCDE12345.")
      #expect(probes == 1)
      #expect(defaults.string(forKey: key) == "ABCDE12345.")
    }
  }

  @Test("A later launch reuses the stored prefix after one entitlement check, without probing")
  func laterLaunchSkipsProbe() throws {
    try withDefaults { defaults in
      _ = makeStore(defaults).prefix(isEntitled: { _ in true }, probe: { "ABCDE12345." })

      let nextLaunch = makeStore(defaults)
      var checks: [String] = []
      var probed = false
      let isEntitled = { (prefix: String) -> Bool in
        checks.append(prefix)
        return true
      }
      let probe = { () -> String? in
        probed = true
        return "OTHER12345."
      }
      #expect(nextLaunch.prefix(isEntitled: isEntitled, probe: probe) == "ABCDE12345.")
      #expect(nextLaunch.prefix(isEntitled: isEntitled, probe: probe) == "ABCDE12345.")
      #expect(checks == ["ABCDE12345."])
      #expect(!probed)
    }
  }

  @Test("A failed probe is not remembered")
  func failedProbeRetries() throws {
    try withDefaults { defaults in
      let store = makeStore(defaults)
      #expect(store.prefix(isEntitled: { _ in true }, probe: { nil }) == nil)
      #expect(defaults.string(forKey: key) == nil)
      #expect(store.prefix(isEntitled: { _ in true }, probe: { "ABCDE12345." }) == "ABCDE12345.")
    }
  }

  @Test("A malformed stored prefix is replaced by a fresh probe without a keychain check")
  func malformedStoredPrefixReprobes() throws {
    try withDefaults { defaults in
      defaults.set("not-a-prefix", forKey: key)
      let store = makeStore(defaults)
      var checked = false
      let prefix = store.prefix(isEntitled: { _ in checked = true; return true }, probe: { "ABCDE12345." })
      #expect(prefix == "ABCDE12345.")
      #expect(!checked)
      #expect(defaults.string(forKey: key) == "ABCDE12345.")
    }
  }

  @Test("A stored prefix the keychain rejects is cleared and re-probed")
  func rejectedStoredPrefixReprobes() throws {
    try withDefaults { defaults in
      defaults.set("STALE12345.", forKey: key)
      let store = makeStore(defaults)
      var probes = 0
      let prefix = store.prefix(isEntitled: { _ in false }, probe: { probes += 1; return "ABCDE12345." })
      #expect(prefix == "ABCDE12345.")
      #expect(probes == 1)
      #expect(defaults.string(forKey: key) == "ABCDE12345.")
    }
  }

  @Test("A rejected stored prefix is cleared even when the probe then fails")
  func rejectedStoredPrefixClearedWhenProbeFails() throws {
    try withDefaults { defaults in
      defaults.set("STALE12345.", forKey: key)
      let store = makeStore(defaults)
      #expect(store.prefix(isEntitled: { _ in false }, probe: { nil }) == nil)
      #expect(defaults.string(forKey: key) == nil)
    }
  }

  @Test("An Info.plist prefix wins without a keychain check or probe")
  func plistPrefixShortCircuits() throws {
    try withDefaults { defaults in
      let store = makeStore(defaults, plistPrefix: "ABCDE12345")
      var touchedKeychain = false
      let prefix = store.prefix(
        isEntitled: { _ in touchedKeychain = true; return true },
        probe: { touchedKeychain = true; return "OTHER12345." }
      )
      #expect(prefix == "ABCDE12345.")
      #expect(!touchedKeychain)
      #expect(defaults.string(forKey: key) == nil)
    }
  }

  @Test("An unexpanded Info.plist build-setting literal is ignored")
  func unexpandedPlistLiteralIgnored() throws {
    try withDefaults { defaults in
      let store = makeStore(defaults, plistPrefix: "$(AppIdentifierPrefix)")
      #expect(store.prefix(isEntitled: { _ in true }, probe: { "ABCDE12345." }) == "ABCDE12345.")
    }
  }

  @Test("invalidate() forgets the in-memory and stored prefix")
  func invalidateClearsBoth() throws {
    try withDefaults { defaults in
      let store = makeStore(defaults)
      _ = store.prefix(isEntitled: { _ in true }, probe: { "ABCDE12345." })
      store.invalidate()
      #expect(defaults.string(forKey: key) == nil)

      var probes = 0
      let prefix = store.prefix(isEntitled: { _ in true }, probe: { probes += 1; return "FGHIJ67890." })
      #expect(prefix == "FGHIJ67890.")
      #expect(probes == 1)
    }
  }
}
