import Foundation
import Petrel
import Testing

@testable import Catbird

// Runs every decision scenario of the golden file (tools/moderation-reference,
// computed by the real @bsky/sdk 1.0.1) through the Swift engine and asserts the
// result in all eight contexts. A scenario with a `catbird` field is held to that
// result instead of the SDK's; the field names the intentional deviation.
//
// The engine models label causes only. Scenarios whose SDK result also holds
// block, mute, muted-word or hidden-post causes (the `restriction` and
// `blockedquote` families) are compared on their label causes: every list is
// reduced to its label entries, and the filter / blur / alert / inform /
// noOverride flags are derived from those entries. For every other scenario the
// derived flags must also equal the flags the golden stores, which proves the
// reduction against the SDK's own output.

// MARK: - Building the engine inputs from a scenario

private enum Conformance {
  static func prefs(_ set: GoldenNormalizedPrefs) -> ModerationPrefs {
    // An empty visibility is no preference at all (see `LabelPreference.init?(storedVisibility:)`).
    func resolved(_ stored: [String: String]) -> [String: LabelPreference] {
      stored.compactMapValues { LabelPreference(storedVisibility: $0) }
    }
    return ModerationPrefs(
      adultContentEnabled: set.adultContentEnabled, labels: resolved(set.labels),
      labelers: set.labelers.map { LabelerModerationPrefs(did: $0.did, labels: resolved($0.labels)) })
  }

  /// The definitions a scenario lists, grouped by the labeler that published them,
  /// in list order, and interpreted by the Swift engine.
  static func labelDefinitions(
    _ scenario: GoldenScenario, golden: ModerationGolden.Loaded
  ) throws -> [String: [ModerationLabelDefinition]] {
    var raw: [String: [ComAtprotoLabelDefs.LabelValueDefinition]] = [:]
    for key in scenario.labelDefKeys {
      let definition = try #require(golden.definitions[key], "\(scenario.id): unknown definition \(key)")
      raw[definition.definedBy, default: []].append(
        try JSONDecoder().decode(ComAtprotoLabelDefs.LabelValueDefinition.self, from: definition.raw))
    }
    var interpreted: [String: [ModerationLabelDefinition]] = [:]
    for (did, definitions) in raw {
      interpreted[did] = ModerationLabelDefinition.interpretAll(definitions, definedBy: did)
    }
    return interpreted
  }

  static func options(_ scenario: GoldenScenario, golden: ModerationGolden.Loaded) throws -> ModerationOptions {
    let set = try #require(golden.prefSets[scenario.prefsKey], "\(scenario.id): unknown prefs \(scenario.prefsKey)")
    return ModerationOptions(
      userDID: scenario.userDid, prefs: prefs(set), labelDefinitions: try labelDefinitions(scenario, golden: golden),
      now: golden.now)
  }

  /// `moderatePost` for a post subject, `moderateProfile` for a profile subject.
  static func decision(_ scenario: GoldenScenario, options: ModerationOptions) throws -> ModerationDecision {
    switch scenario.kind {
    case "post":
      let post = try JSONDecoder().decode(AppBskyFeedDefs.PostView.self, from: scenario.subject)
      return ModerationSubjects.decidePost(post, options: options)
    case "profile":
      let profile = try JSONDecoder().decode(AppBskyActorDefs.ProfileViewDetailed.self, from: scenario.subject)
      return ModerationSubjects.decideProfileSubject(profile, options: options)
    default:
      throw GoldenFormatError("\(scenario.id): unknown subject kind \(scenario.kind)")
    }
  }
}

// MARK: - Comparable summaries

private extension ModerationCause {
  var contextKey: GoldenCauseKey {
    GoldenCauseKey(val: label.val, src: labelerDID, target: target.rawValue, priority: priority)
  }
}

/// One entry of `decision.causes`, reduced to what both sides can state.
private struct CauseSummary: Equatable, CustomStringConvertible {
  let val: String
  let src: String
  let target: String
  let setting: String
  let priority: Int
  let source: String
  let noOverride: Bool
  let downgraded: Bool

  var description: String {
    "\(val) from \(src) on \(target): \(setting), priority \(priority), source \(source)"
      + (noOverride ? ", noOverride" : "") + (downgraded ? ", downgraded" : "")
  }

  init(_ cause: ModerationCause) {
    val = cause.label.val
    src = cause.labelerDID
    target = cause.target.rawValue
    setting = cause.setting.rawValue
    priority = cause.priority
    switch cause.source {
    case .user: source = "user"
    case .labeler: source = "labeler"
    }
    noOverride = cause.noOverride
    downgraded = cause.downgraded
  }

  /// A golden label cause. The SDK holds a stored visibility it does not recognize
  /// as is (`block`); the engine acts on it as warn, so the golden setting is read
  /// the way the SDK's decision logic acts on it.
  init(_ golden: GoldenCause) {
    val = golden.val ?? ""
    src = golden.src ?? ""
    target = golden.target ?? ""
    let stored = golden.setting ?? ""
    setting = GoldenVisibility.effective(stored) ?? stored
    priority = golden.priority
    source = golden.source
    noOverride = golden.noOverride
    downgraded = golden.downgraded
  }
}

/// A golden context reduced to label causes.
private struct LabelContext {
  let filters: [GoldenCauseKey]
  let blurs: [GoldenCauseKey]
  let alerts: [GoldenCauseKey]
  let informs: [GoldenCauseKey]
  let noOverride: Bool

  var filter: Bool { !filters.isEmpty }
  var blur: Bool { !blurs.isEmpty }
  var alert: Bool { !alerts.isEmpty }
  var inform: Bool { !informs.isEmpty }

  init(_ context: GoldenContext, in expectation: GoldenExpectation) {
    let blurring = context.blurs.compactMap(\.labelKey)
    // `noOverride` is set when a blurring label cause is no-override and the subject is not the viewer.
    let locked = expectation.labelCauses.filter(\.noOverride)
    filters = context.filters.compactMap(\.labelKey)
    blurs = blurring
    alerts = context.alerts.compactMap(\.labelKey)
    informs = context.informs.compactMap(\.labelKey)
    noOverride =
      !expectation.isMe
      && blurring.contains { key in
        locked.contains { $0.val == key.val && $0.src == key.src && $0.target == key.target && $0.priority == key.priority }
      }
  }
}

// MARK: - Definition comparison

/// Compare an engine definition with the SDK's, field by field and behavior by behavior.
private func expectDefinition(
  _ actual: ModerationLabelDefinition, _ golden: GoldenInterpretedDefinition, _ name: String,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(actual.identifier == golden.identifier, "\(name): identifier", sourceLocation: sourceLocation)
  #expect(actual.configurable == golden.configurable, "\(name): configurable", sourceLocation: sourceLocation)
  #expect(actual.defaultSetting.rawValue == golden.defaultSetting, "\(name): defaultSetting", sourceLocation: sourceLocation)
  #expect(Set(actual.flags.map(\.rawValue)) == golden.flags, "\(name): flags", sourceLocation: sourceLocation)
  // The SDK passes a `blurs` / `severity` it does not recognize through unchanged; the engine's closed enums hold
  // `none` for it. Its behaviors, compared below, are what decides, so the raw strings are compared only when
  // the SDK's value is one of the recognized ones, and an unrecognized one must be held as `none`.
  if LabelBlurs(rawValue: golden.blurs) != nil {
    #expect(actual.blurs.rawValue == golden.blurs, "\(name): blurs", sourceLocation: sourceLocation)
  } else {
    #expect(actual.blurs == .none, "\(name): unrecognized blurs \(golden.blurs) is held as none", sourceLocation: sourceLocation)
  }
  if LabelSeverity(rawValue: golden.severity) != nil {
    #expect(actual.severity.rawValue == golden.severity, "\(name): severity", sourceLocation: sourceLocation)
  } else {
    #expect(actual.severity == .none, "\(name): unrecognized severity \(golden.severity) is held as none", sourceLocation: sourceLocation)
  }
  #expect(actual.definedBy == golden.definedBy, "\(name): definedBy", sourceLocation: sourceLocation)
  #expect(
    actual.locales.map { GoldenLocale(lang: $0.lang, name: $0.name, description: $0.description) } == golden.locales,
    "\(name): locales", sourceLocation: sourceLocation)

  for target in LabelTarget.allCases {
    let wanted = golden.behaviors[target.rawValue] ?? [:]
    for context in ModerationContext.allCases {
      #expect(
        actual.behaviors[target]?[context]?.rawValue == wanted[context.rawValue],
        "\(name): behaviors.\(target.rawValue).\(context.rawValue)", sourceLocation: sourceLocation)
    }
    #expect(
      Set(wanted.keys).isSubset(of: Set(ModerationContext.allCases.map(\.rawValue))),
      "\(name): unknown context in behaviors.\(target.rawValue)", sourceLocation: sourceLocation)
  }
  #expect(
    Set(golden.behaviors.keys).isSubset(of: Set(LabelTarget.allCases.map(\.rawValue))),
    "\(name): unknown target in behaviors", sourceLocation: sourceLocation)
}

// MARK: - Suite

@Suite("Moderation: conformance with the Bluesky SDK")
struct ModerationReferenceConformanceTests {
  private static let restrictionFamilies: Set<String> = ["restriction", "blockedquote"]

  @Test("The golden file loads, and every scenario and preference case is accounted for")
  func goldenIsComplete() throws {
    let golden = try ModerationGolden.shared()
    #expect(golden.sdkVersion == ModerationReferenceGolden.sdkVersion)
    #expect(golden.scenarios.count == golden.declaredScenarioCount)
    #expect(golden.scenarioByID.count == golden.scenarios.count, "scenario ids are unique")
    #expect(golden.prefCases.count == golden.declaredPrefCaseCount)
    #expect(golden.prefCaseByID.count == golden.prefCases.count, "preference case ids are unique")
    #expect(golden.scenarios.count >= 340)
    #expect(golden.builtinLabels.count == 8, "seven labels.json entries plus the deprecated alias")

    var byFamily: [String: Int] = [:]
    for scenario in golden.scenarios { byFamily[scenario.family, default: 0] += 1 }
    #expect(byFamily == golden.declaredScenariosByFamily)

    for scenario in golden.scenarios {
      #expect(golden.prefSets[scenario.prefsKey] != nil, "\(scenario.id): prefs \(scenario.prefsKey)")
      for key in scenario.labelDefKeys { #expect(golden.definitions[key] != nil, "\(scenario.id): definition \(key)") }
      if scenario.catbird != nil {
        #expect(scenario.family == "deviation", "\(scenario.id): only deviation scenarios carry a catbird field")
      }
      if scenario.expected.hasOtherCauses {
        #expect(
          Self.restrictionFamilies.contains(scenario.family),
          "\(scenario.id): block / mute / muted-word / hidden causes outside the restriction families")
      }
    }

    // Families the launch behavior depends on must be present.
    let requiredFamilies = [
      "post", "post-account", "quote", "profile-account", "custom", "unknown", "order", "multi", "restriction",
      "blockedquote", "deviation", "unknown-visibility"
    ]
    for family in requiredFamilies {
      #expect(byFamily[family, default: 0] > 0, "family \(family)")
    }
  }

  @Test("Every scenario matches the SDK, or its intentional Catbird deviation, in all eight contexts", arguments: ModerationGolden.scenarioIDs)
  func scenario(id: String) throws {
    let golden = try ModerationGolden.shared()
    let scenario = try #require(golden.scenarioByID[id])
    let expected = scenario.effectiveExpected

    let options = try Conformance.options(scenario, golden: golden)
    let decision = try Conformance.decision(scenario, options: options)

    for context in ModerationContext.allCases {
      let actual = decision.ui(context)
      let stored = expected.contexts[context.rawValue] ?? GoldenContext()
      let wanted = LabelContext(stored, in: expected)
      let place = "\(id) [\(context.rawValue)]"

      #expect(actual.filters.map(\.contextKey) == wanted.filters, "\(place): filters")
      #expect(actual.blurs.map(\.contextKey) == wanted.blurs, "\(place): blurs")
      #expect(actual.alerts.map(\.contextKey) == wanted.alerts, "\(place): alerts")
      #expect(actual.informs.map(\.contextKey) == wanted.informs, "\(place): informs")
      #expect(actual.filter == wanted.filter, "\(place): filter")
      #expect(actual.blur == wanted.blur, "\(place): blur")
      #expect(actual.alert == wanted.alert, "\(place): alert")
      #expect(actual.inform == wanted.inform, "\(place): inform")
      #expect(actual.noOverride == wanted.noOverride, "\(place): noOverride")

      // Without other causes the reduction is the identity, so the flags the golden stores must agree with it.
      if !expected.hasOtherCauses {
        #expect(stored.filter == wanted.filter, "\(place): stored filter flag disagrees with its causes")
        #expect(stored.blur == wanted.blur, "\(place): stored blur flag disagrees with its causes")
        #expect(stored.alert == wanted.alert, "\(place): stored alert flag disagrees with its causes")
        #expect(stored.inform == wanted.inform, "\(place): stored inform flag disagrees with its causes")
        #expect(stored.noOverride == wanted.noOverride, "\(place): stored noOverride flag disagrees with its causes")
      }
    }

    #expect(decision.isMe == expected.isMe, "\(id): isMe")
    #expect(
      decision.causes.map(CauseSummary.init) == expected.labelCauses.map(CauseSummary.init),
      "\(id): decision.causes")
  }

  @Test("Interpreted label definitions equal the SDK's, except those Catbird refuses to represent", arguments: ModerationGolden.definitionKeys)
  func interpretedDefinition(key: String) throws {
    let golden = try ModerationGolden.shared()
    let definition = try #require(golden.definitions[key])
    let raw = try JSONDecoder().decode(ComAtprotoLabelDefs.LabelValueDefinition.self, from: definition.raw)
    let actual = ModerationLabelDefinition.interpret(raw, definedBy: definition.definedBy)

    guard let wanted = definition.interpreted else {
      #expect(actual == nil, "\(key): the SDK drops this definition")
      return
    }

    // The only intentional differences: Catbird drops a definition of a reserved identifier (a builtin or a
    // "!" value) and one whose identifier is not ^[a-z-]+$. The SDK interprets both but can never look the
    // second up, and Catbird's lookup never reaches the first.
    let reserved = ModerationLabelDefinition.isReservedIdentifier(definition.rawIdentifier)
    let malformed = !ModerationLabelDefinition.isValidCustomIdentifier(definition.rawIdentifier)
    if reserved || malformed {
      #expect(actual == nil, "\(key): Catbird does not represent \(definition.rawIdentifier)")
      return
    }
    guard let actual else {
      Issue.record("\(key): the engine dropped a definition the SDK keeps")
      return
    }
    expectDefinition(actual, wanted, key)
  }

  @Test("The builtin table equals the SDK's LABELS table, the deprecated alias included")
  func builtinTable() throws {
    let golden = try ModerationGolden.shared()
    #expect(Set(ModerationLabelDefinition.builtins.keys) == Set(golden.builtinLabels.keys))
    for (identifier, wanted) in golden.builtinLabels {
      guard let actual = ModerationLabelDefinition.builtins[identifier] else {
        Issue.record("missing builtin \(identifier)")
        continue
      }
      expectDefinition(actual, wanted, "builtin \(identifier)")
    }
  }

  @Test("The seeded preference defaults equal the SDK's DEFAULT_LABEL_SETTINGS")
  func seededDefaults() throws {
    let golden = try ModerationGolden.shared()
    #expect(ModerationPrefs.builtinDefaultLabels.mapValues(\.rawValue) == golden.defaultLabelSettings)
  }

  @Test("Scenarios that consult a definition with an unrecognized blurs or severity are present, so both are exercised end to end")
  func unrecognizedDefinitionValuesAreExercised() throws {
    let golden = try ModerationGolden.shared()
    let used = Set(golden.scenarios.flatMap(\.labelDefKeys)).compactMap { golden.definitions[$0]?.interpreted }
    #expect(used.contains { LabelBlurs(rawValue: $0.blurs) == nil }, "a definition with an unrecognized blurs")
    #expect(used.contains { LabelSeverity(rawValue: $0.severity) == nil }, "a definition with an unrecognized severity")
    // An unrecognized blurs has no behaviors in any target; an unrecognized severity never alerts or informs.
    for definition in used where LabelBlurs(rawValue: definition.blurs) == nil {
      let behaviorCount = definition.behaviors.values.reduce(0) { $0 + $1.count }
      #expect(behaviorCount == 0, "\(definition.identifier): the SDK gives an unknown blurs no behavior")
    }
    for definition in used where LabelSeverity(rawValue: definition.severity) == nil {
      let actions = Set(definition.behaviors.values.flatMap { $0.values })
      #expect(actions.isSubset(of: ["blur"]), "\(definition.identifier): the SDK gives an unknown severity no alert or inform")
    }
  }

  @Test("Scenarios that consult an unknown stored visibility are present, so its reading is exercised end to end")
  func unknownVisibilityIsExercised() throws {
    let golden = try ModerationGolden.shared()
    let sets = golden.scenarios.compactMap { golden.prefSets[$0.prefsKey] }
    let recognized: Set<String> = ["ignore", "warn", "hide"]
    #expect(sets.contains { $0.labels.values.contains { !$0.isEmpty && !recognized.contains($0) } }, "a global unknown value")
    #expect(sets.contains { $0.labelers.contains { $0.labels.values.contains { !$0.isEmpty && !recognized.contains($0) } } }, "a scoped unknown value")
    #expect(sets.contains { $0.labels.values.contains("") }, "an empty global value")
    #expect(sets.contains { $0.labelers.contains { $0.labels.values.contains("") } }, "an empty scoped value")
  }
}
