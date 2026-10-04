import Foundation
import SwiftUI
import Testing
import Petrel
@testable import Catbird

@Suite("ContentLabelPolicyTests", .serialized)
struct ContentLabelPolicyTests {
  private func definition(_ blurs: String = "content", defaultSetting: String? = nil) -> ComAtprotoLabelDefs.LabelValueDefinition {
    .init(identifier: "custom", severity: "alert", blurs: blurs, defaultSetting: defaultSetting, locales: [])
  }

  @Test("Custom Warn honors exact scoped policy and preserves targets")
  func customWarningClassification() throws {
    let a = try DID(didString: "did:plc:service-a")
    let b = try DID(didString: "did:plc:service-b")
    let preferences: [ContentLabelPreference] = [
      .init(labelerDid: nil, label: "custom", visibility: "hide"),
      .init(labelerDid: a, label: "custom", visibility: "warn"),
      .init(labelerDid: b, label: "custom", visibility: "ignore")]
    func result(_ definition: ComAtprotoLabelDefs.LabelValueDefinition?, _ type: String = "post", _ active: Bool = true) -> ContentVisibility? {
      CustomContentLabelPolicy.visibility(labelValue: "custom", labelerDID: a, preferences: preferences,
        definition: definition, contentType: type, isActive: active)
    }
    #expect(result(nil) == .warn)
    #expect(result(definition()) == .warn)
    #expect(result(definition("media"), "media") == .warn)
    #expect(result(definition("media"), "post") == .show)
    #expect(result(definition("none")) == .show)
    #expect(result(nil, "post", false) == nil)
  }

  @Test("Missing metadata invents no default and another service never supplies one")
  func missingDefinitionAndInheritance() throws {
    let a = try DID(didString: "did:plc:service-a")
    let b = try DID(didString: "did:plc:service-b")
    let other: [ContentLabelPreference] = [.init(labelerDid: b, label: "custom", visibility: "hide")]
    #expect(CustomContentLabelPolicy.visibility(labelValue: "custom", labelerDID: a, preferences: other,
      definition: nil, contentType: "post", isActive: true) == nil)
    #expect(CustomContentLabelPolicy.visibility(labelValue: "custom", labelerDID: a, preferences: other,
      definition: definition(defaultSetting: "warn"), contentType: "post", isActive: true) == .warn)
    #expect(CustomContentLabelPolicy.visibility(labelValue: "!warn", labelerDID: a, preferences: [],
      definition: definition(defaultSetting: "hide"), contentType: "post", isActive: true) == nil)
  }

  @Test("Builtin initial policy and self-label gate remain unchanged")
  func builtinInitialFixtures() throws {
    for value in ["nsfw", "porn", "sexual"] {
      #expect(ContentLabelManager<Text>.getInitialContentVisibility(labels: nil, selfLabelValues: [value]) == .hide)
    }
    for value in ["nudity", "suggestive", "gore", "graphic", "self-harm"] {
      #expect(ContentLabelManager<Text>.getInitialContentVisibility(labels: nil, selfLabelValues: [value]) == .warn)
    }
    #expect(ContentLabelManager<Text>.getInitialContentVisibility(labels: nil, selfLabelValues: ["bot", "custom", "!warn"]) == .show)
  }

  @Test("Definition lookups coalesce, fence account changes, and retry failures")
  @MainActor
  func definitionLookupBoundary() async throws {
    let lookup = ContentLabelDefinitionLookup()
    let identity = NSObject()
    let key = ContentLabelDefinitionLookup.Key(accountDID: "A", clientIdentity: ObjectIdentifier(identity), subscriptions: ["service"])
    let fixture = LabelDefinitionFixture()
    fixture.pause = true
    let first = Task { try await lookup.definitions(for: key, isCurrent: { fixture.account == "A" }, load: { try await fixture.load() }) }
    try await fixture.waitForGate()
    let second = Task { try await lookup.definitions(for: key, isCurrent: { fixture.account == "A" }, load: { try await fixture.load() }) }
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.loads == 1)
    fixture.account = "B"
    fixture.resume()
    do { _ = try await first.value; Issue.record("Expected account fence") } catch {}
    do { _ = try await second.value; Issue.record("Expected account fence") } catch {}
    fixture.account = "A"; fixture.fail = true
    do { _ = try await lookup.definitions(for: key, isCurrent: { true }, load: { try await fixture.load() }); Issue.record("Expected lookup failure") } catch {}
    let failureLoads = fixture.loads
    fixture.fail = false
    let result = try await lookup.definitions(for: key, isCurrent: { true }, load: { try await fixture.load() })
    #expect(fixture.loads == failureLoads + 1)
    #expect(result["service"]?.first?.identifier == "custom")
    _ = try await lookup.definitions(for: key, isCurrent: { true }, load: { try await fixture.load() })
    #expect(fixture.loads == failureLoads + 1)
  }
}

@MainActor
private final class LabelDefinitionFixture {
  var account = "A"
  var loads = 0
  var fail = false
  var pause = false
  var gate: CheckedContinuation<Void, Never>?
  func load() async throws -> ContentLabelDefinitionLookup.Definitions {
    loads += 1
    if pause { pause = false; await withCheckedContinuation { gate = $0 } }
    if fail { throw PreferencesManagerError.invalidData }
    return ["service": [.init(identifier: "custom", severity: "alert", blurs: "content", defaultSetting: "warn", locales: [])]]
  }
  func waitForGate() async throws {
    for _ in 0..<1000 { if gate != nil { return }; await Task.yield() }
    throw PreferencesManagerError.invalidData
  }
  func resume() { gate?.resume(); gate = nil }
}
