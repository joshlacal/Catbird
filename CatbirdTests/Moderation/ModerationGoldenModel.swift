import Foundation

// Typed, Sendable view of `ModerationReferenceGolden.json` (see
// tools/moderation-reference/README.md for the schema). The conformance and
// preference suites both read the golden through `ModerationGolden`.

// MARK: - Format errors

struct GoldenFormatError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private typealias JSONObject = [String: Any]

private extension Dictionary where Key == String, Value == Any {
  func string(_ key: String) throws -> String {
    guard let value = self[key] as? String else { throw GoldenFormatError("missing string \"\(key)\"") }
    return value
  }

  func int(_ key: String) throws -> Int {
    guard let value = (self[key] as? NSNumber)?.intValue else { throw GoldenFormatError("missing number \"\(key)\"") }
    return value
  }

  func flag(_ key: String) -> Bool { (self[key] as? Bool) ?? false }

  func object(_ key: String) throws -> JSONObject {
    guard let value = self[key] as? JSONObject else { throw GoldenFormatError("missing object \"\(key)\"") }
    return value
  }

  func objects(_ key: String) -> [JSONObject] { (self[key] as? [JSONObject]) ?? [] }

  func strings(_ key: String) -> [String] { (self[key] as? [String]) ?? [] }
}

// MARK: - Causes and contexts

/// A label cause as the golden lists it inside a context: `{val, src, target, priority}`.
struct GoldenCauseKey: Sendable, Equatable, CustomStringConvertible {
  let val: String
  let src: String
  let target: String
  let priority: Int

  var description: String { "\(val) from \(src) on \(target) (priority \(priority))" }
}

/// One entry of a context's `filters` / `blurs` / `alerts` / `informs`. Entries
/// without a `type` are label causes; blocks, mutes, muted words and hidden
/// posts carry a `type` and are not modeled by the Catbird engine.
enum GoldenEntry: Sendable, Equatable {
  case label(GoldenCauseKey)
  case other(type: String)

  var labelKey: GoldenCauseKey? {
    if case .label(let key) = self { return key }
    return nil
  }
}

struct GoldenContext: Sendable {
  var filter = false
  var blur = false
  var alert = false
  var inform = false
  var noOverride = false
  var filters: [GoldenEntry] = []
  var blurs: [GoldenEntry] = []
  var alerts: [GoldenEntry] = []
  var informs: [GoldenEntry] = []
}

/// One entry of `decision.causes`.
struct GoldenCause: Sendable {
  let type: String
  let val: String?
  let src: String?
  let target: String?
  let setting: String?
  let priority: Int
  let source: String
  let noOverride: Bool
  let downgraded: Bool

  var isLabel: Bool { type == "label" }
}

struct GoldenExpectation: Sendable {
  let contexts: [String: GoldenContext]
  let causes: [GoldenCause]
  let isMe: Bool

  var labelCauses: [GoldenCause] { causes.filter(\.isLabel) }
  var hasOtherCauses: Bool { causes.contains { !$0.isLabel } }
}

// MARK: - Scenarios

struct GoldenScenario: Sendable {
  struct Deviation: Sendable {
    let reason: String
    let expected: GoldenExpectation
  }

  let id: String
  let kind: String
  let shape: String
  /// `nil` is a logged-out viewer.
  let userDid: String?
  let prefsKey: String
  let labelDefKeys: [String]
  /// The subject as JSON, ready to decode into the typed model.
  let subject: Data
  let expected: GoldenExpectation
  let catbird: Deviation?

  /// What Catbird must produce: the SDK's result, or the intentional deviation's.
  var effectiveExpected: GoldenExpectation { catbird?.expected ?? expected }
  var family: String { String(id.split(separator: "/").first ?? "") }
}

// MARK: - Preferences and definitions

struct GoldenLabelerPrefs: Sendable {
  let did: String
  let labels: [String: String]
}

/// The output of the real `getPreferences()`: visibilities are strings exactly as the SDK holds them.
struct GoldenNormalizedPrefs: Sendable {
  let adultContentEnabled: Bool
  let labels: [String: String]
  let labelers: [GoldenLabelerPrefs]
}

struct GoldenStoredPref: Sendable {
  let label: String
  let visibility: String
  let labelerDid: String?
}

struct GoldenPrefCase: Sendable {
  struct Deviation: Sendable {
    let reason: String
    let expected: GoldenNormalizedPrefs
  }

  let id: String
  let raw: [GoldenStoredPref]
  /// The stored adult-content preference; `nil` when the account has none.
  let adultContentEnabled: Bool?
  let labelers: [String]
  let normalized: GoldenNormalizedPrefs
  let catbird: Deviation?

  var effectiveExpected: GoldenNormalizedPrefs { catbird?.expected ?? normalized }
}

struct GoldenLocale: Sendable, Equatable {
  let lang: String
  let name: String
  let description: String
}

/// A label definition as the SDK's interpreter (or its builtin `LABELS` table) holds it.
struct GoldenInterpretedDefinition: Sendable {
  let identifier: String
  let severity: String
  let blurs: String
  let defaultSetting: String
  let configurable: Bool
  let flags: Set<String>
  let definedBy: String?
  /// target -> context -> action
  let behaviors: [String: [String: String]]
  let locales: [GoldenLocale]
}

struct GoldenDefinition: Sendable {
  let key: String
  let definedBy: String
  /// What the labeler service publishes.
  let raw: Data
  let rawIdentifier: String
  /// `nil` when the SDK drops the definition.
  let interpreted: GoldenInterpretedDefinition?
}

// MARK: - Reading a stored visibility

enum GoldenVisibility {
  /// What the SDK's decision logic acts on for a visibility string it holds: the
  /// empty string is falsy (no preference), `ignore` and `show` ignore, `hide` hides,
  /// and every other string, `warn` included, is neither and acts as `warn`.
  ///
  /// Written out separately from `LabelPreference.init?(storedVisibility:)` so the
  /// suites compare the engine with this statement of the SDK rule, not with itself.
  static func effective(_ stored: String) -> String? {
    switch stored {
    case "": nil
    case "ignore", "show": "ignore"
    case "hide": "hide"
    default: "warn"
    }
  }
}

// MARK: - Loaded golden

enum ModerationGolden {
  struct Loaded: Sendable {
    let sdkVersion: String
    let now: Date
    let declaredScenarioCount: Int
    let declaredPrefCaseCount: Int
    let declaredScenariosByFamily: [String: Int]
    let defaultLabelSettings: [String: String]
    /// The SDK's `LABELS` table, keyed by identifier (aliases included).
    let builtinLabels: [String: GoldenInterpretedDefinition]
    let prefSets: [String: GoldenNormalizedPrefs]
    let definitions: [String: GoldenDefinition]
    let scenarios: [GoldenScenario]
    let prefCases: [GoldenPrefCase]

    let scenarioByID: [String: GoldenScenario]
    let prefCaseByID: [String: GoldenPrefCase]
  }

  private static let result: Result<Loaded, any Error> = Result { try parse(ModerationReferenceGolden.json) }

  static func shared() throws -> Loaded { try result.get() }

  /// Scenario ids, for parameterized tests. Empty if the file cannot be read; the
  /// suite's loading test reports why.
  static var scenarioIDs: [String] { (try? shared().scenarios.map(\.id)) ?? [] }
  static var definitionKeys: [String] { (try? shared().definitions.keys.sorted()) ?? [] }
  static var prefCaseIDs: [String] { (try? shared().prefCases.map(\.id)) ?? [] }
}

// MARK: - Parsing

private extension ModerationGolden {
  static func parse(_ text: String) throws -> Loaded {
    guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSONObject else {
      throw GoldenFormatError("the golden root is not an object")
    }
    let meta = try root.object("meta")
    let counts = try meta.object("counts")

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let now = formatter.date(from: try meta.string("now")) else { throw GoldenFormatError("meta.now is not a date") }

    var builtins: [String: GoldenInterpretedDefinition] = [:]
    for (key, value) in try meta.object("builtinLabels") {
      guard let object = value as? JSONObject else { throw GoldenFormatError("builtin \(key) is not an object") }
      builtins[key] = try interpretedDefinition(object)
    }

    var prefSets: [String: GoldenNormalizedPrefs] = [:]
    for (key, value) in try root.object("prefSets") {
      guard let object = value as? JSONObject else { throw GoldenFormatError("prefSet \(key) is not an object") }
      prefSets[key] = try normalizedPrefs(object)
    }

    var definitions: [String: GoldenDefinition] = [:]
    for (key, value) in try root.object("definitions") {
      guard let object = value as? JSONObject else { throw GoldenFormatError("definition \(key) is not an object") }
      let raw = try object.object("raw")
      definitions[key] = GoldenDefinition(
        key: key, definedBy: try object.string("definedBy"),
        raw: try JSONSerialization.data(withJSONObject: raw), rawIdentifier: try raw.string("identifier"),
        interpreted: try (object["interpreted"] as? JSONObject).map(interpretedDefinition))
    }

    let scenarios = try root.objects("scenarios").map(scenario)
    let prefCases = try root.objects("prefs").map(prefCase)

    var byFamily: [String: Int] = [:]
    for (family, value) in try counts.object("scenariosByFamily") {
      byFamily[family] = (value as? NSNumber)?.intValue
    }

    return Loaded(
      sdkVersion: try meta.string("sdkVersion"), now: now,
      declaredScenarioCount: try counts.int("scenarios"), declaredPrefCaseCount: try counts.int("prefs"),
      declaredScenariosByFamily: byFamily,
      defaultLabelSettings: try meta.object("defaultLabelSettings").compactMapValues { $0 as? String },
      builtinLabels: builtins, prefSets: prefSets, definitions: definitions, scenarios: scenarios, prefCases: prefCases,
      scenarioByID: Dictionary(scenarios.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      prefCaseByID: Dictionary(prefCases.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
  }

  static func labelerPrefs(_ object: JSONObject) throws -> GoldenLabelerPrefs {
    GoldenLabelerPrefs(
      did: try object.string("did"), labels: try object.object("labels").compactMapValues { $0 as? String })
  }

  static func normalizedPrefs(_ object: JSONObject) throws -> GoldenNormalizedPrefs {
    GoldenNormalizedPrefs(
      adultContentEnabled: object.flag("adultContentEnabled"),
      labels: try object.object("labels").compactMapValues { $0 as? String },
      labelers: try object.objects("labelers").map(labelerPrefs))
  }

  static func storedPref(_ object: JSONObject) throws -> GoldenStoredPref {
    GoldenStoredPref(
      label: try object.string("label"), visibility: try object.string("visibility"),
      labelerDid: object["labelerDid"] as? String)
  }

  static func prefCase(_ object: JSONObject) throws -> GoldenPrefCase {
    var deviation: GoldenPrefCase.Deviation?
    if let catbird = object["catbird"] as? JSONObject {
      deviation = GoldenPrefCase.Deviation(
        reason: try catbird.string("reason"), expected: try normalizedPrefs(try catbird.object("expected")))
    }
    return GoldenPrefCase(
      id: try object.string("id"), raw: try object.objects("raw").map(storedPref),
      adultContentEnabled: object["adultContentEnabled"] as? Bool, labelers: object.strings("labelers"),
      normalized: try normalizedPrefs(try object.object("normalized")), catbird: deviation)
  }

  static func interpretedDefinition(_ object: JSONObject) throws -> GoldenInterpretedDefinition {
    var behaviors: [String: [String: String]] = [:]
    for (target, value) in try object.object("behaviors") {
      behaviors[target] = (value as? JSONObject)?.compactMapValues { $0 as? String } ?? [:]
    }
    let locales = try object.objects("locales").map {
      GoldenLocale(lang: try $0.string("lang"), name: try $0.string("name"), description: try $0.string("description"))
    }
    return GoldenInterpretedDefinition(
      identifier: try object.string("identifier"), severity: try object.string("severity"),
      blurs: try object.string("blurs"), defaultSetting: try object.string("defaultSetting"),
      configurable: object.flag("configurable"), flags: Set(object.strings("flags")),
      definedBy: object["definedBy"] as? String, behaviors: behaviors, locales: locales)
  }

  static func entry(_ object: JSONObject) throws -> GoldenEntry {
    if let type = object["type"] as? String { return .other(type: type) }
    return .label(
      GoldenCauseKey(
        val: try object.string("val"), src: try object.string("src"), target: try object.string("target"),
        priority: try object.int("priority")))
  }

  static func context(_ object: JSONObject) throws -> GoldenContext {
    GoldenContext(
      filter: object.flag("filter"), blur: object.flag("blur"), alert: object.flag("alert"),
      inform: object.flag("inform"), noOverride: object.flag("noOverride"),
      filters: try object.objects("filters").map(entry), blurs: try object.objects("blurs").map(entry),
      alerts: try object.objects("alerts").map(entry), informs: try object.objects("informs").map(entry))
  }

  static func expectation(_ object: JSONObject) throws -> GoldenExpectation {
    var contexts: [String: GoldenContext] = [:]
    for (name, value) in try object.object("contexts") {
      guard let body = value as? JSONObject else { throw GoldenFormatError("context \(name) is not an object") }
      contexts[name] = try context(body)
    }
    let decision = try object.object("decision")
    let causes = try decision.objects("causes").map { cause in
      GoldenCause(
        type: try cause.string("type"), val: cause["val"] as? String, src: cause["src"] as? String,
        target: cause["target"] as? String, setting: cause["setting"] as? String, priority: try cause.int("priority"),
        source: try cause.string("source"), noOverride: cause.flag("noOverride"), downgraded: cause.flag("downgraded"))
    }
    return GoldenExpectation(contexts: contexts, causes: causes, isMe: decision.flag("isMe"))
  }

  static func scenario(_ object: JSONObject) throws -> GoldenScenario {
    let input = try object.object("input")
    var deviation: GoldenScenario.Deviation?
    if let catbird = object["catbird"] as? JSONObject {
      deviation = GoldenScenario.Deviation(
        reason: try catbird.string("reason"), expected: try expectation(try catbird.object("expected")))
    }
    return GoldenScenario(
      id: try object.string("id"), kind: try input.string("kind"), shape: try input.string("shape"),
      userDid: input["userDid"] as? String, prefsKey: try input.string("prefs"), labelDefKeys: input.strings("labelDefs"),
      subject: try JSONSerialization.data(withJSONObject: try input.object("subject")),
      expected: try expectation(try object.object("expected")), catbird: deviation)
  }
}
