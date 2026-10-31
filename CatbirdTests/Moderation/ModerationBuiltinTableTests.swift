import Foundation
import Testing

@testable import Catbird

// Asserts the builtin label table against `atproto/packages/api/definitions/labels.json`.
//
// `labelsJSON` below is a verbatim copy of that file, so the table is checked
// without needing the atproto checkout at test time. `upstreamFileMatchesEmbeddedCopy`
// also compares the copy with the live file when the checkout is reachable
// from this source file, so drift is caught on developer machines. Without the
// checkout that test is reported as skipped, never as passed.

private let labelsJSON = #"""
[
  {
    "identifier": "!hide",
    "configurable": false,
    "defaultSetting": "hide",
    "flags": ["no-override", "no-self"],
    "severity": "alert",
    "blurs": "content",
    "behaviors": {
      "account": {
        "profileList": "blur",
        "profileView": "blur",
        "avatar": "blur",
        "banner": "blur",
        "displayName": "blur",
        "contentList": "blur",
        "contentView": "blur"
      },
      "profile": {
        "avatar": "blur",
        "banner": "blur",
        "displayName": "blur"
      },
      "content": {
        "contentList": "blur",
        "contentView": "blur"
      }
    }
  },
  {
    "identifier": "!warn",
    "configurable": false,
    "defaultSetting": "warn",
    "flags": ["no-self"],
    "severity": "none",
    "blurs": "content",
    "behaviors": {
      "account": {
        "profileList": "blur",
        "profileView": "blur",
        "avatar": "blur",
        "banner": "blur",
        "contentList": "blur",
        "contentView": "blur"
      },
      "profile": {
        "avatar": "blur",
        "banner": "blur",
        "displayName": "blur"
      },
      "content": {
        "contentList": "blur",
        "contentView": "blur"
      }
    }
  },
  {
    "identifier": "!no-unauthenticated",
    "configurable": false,
    "defaultSetting": "hide",
    "flags": ["no-override", "unauthed"],
    "severity": "none",
    "blurs": "content",
    "behaviors": {
      "account": {
        "profileList": "blur",
        "profileView": "blur",
        "avatar": "blur",
        "banner": "blur",
        "displayName": "blur",
        "contentList": "blur",
        "contentView": "blur"
      },
      "profile": {
        "avatar": "blur",
        "banner": "blur",
        "displayName": "blur"
      },
      "content": {
        "contentList": "blur",
        "contentView": "blur"
      }
    }
  },
  {
    "identifier": "porn",
    "configurable": true,
    "defaultSetting": "hide",
    "flags": ["adult"],
    "severity": "none",
    "blurs": "media",
    "behaviors": {
      "account": {
        "avatar": "blur",
        "banner": "blur"
      },
      "profile": {
        "avatar": "blur",
        "banner": "blur"
      },
      "content": {
        "contentMedia": "blur"
      }
    }
  },
  {
    "identifier": "sexual",
    "configurable": true,
    "defaultSetting": "warn",
    "flags": ["adult"],
    "severity": "none",
    "blurs": "media",
    "behaviors": {
      "account": {
        "avatar": "blur",
        "banner": "blur"
      },
      "profile": {
        "avatar": "blur",
        "banner": "blur"
      },
      "content": {
        "contentMedia": "blur"
      }
    }
  },
  {
    "identifier": "nudity",
    "configurable": true,
    "defaultSetting": "ignore",
    "flags": [],
    "severity": "none",
    "blurs": "media",
    "behaviors": {
      "account": {
        "avatar": "blur",
        "banner": "blur"
      },
      "profile": {
        "avatar": "blur",
        "banner": "blur"
      },
      "content": {
        "contentMedia": "blur"
      }
    }
  },
  {
    "identifier": "graphic-media",
    "alias": ["gore"],
    "flags": ["adult"],
    "configurable": true,
    "defaultSetting": "warn",
    "severity": "none",
    "blurs": "media",
    "behaviors": {
      "account": {
        "avatar": "blur",
        "banner": "blur"
      },
      "profile": {
        "avatar": "blur",
        "banner": "blur"
      },
      "content": {
        "contentMedia": "blur"
      }
    }
  }
]
"""#

private func parsedLabels() throws -> [[String: Any]] {
  let data = Data(labelsJSON.utf8)
  return try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
}

/// The upstream entries plus, for each `alias`, a copy of its entry under the
/// alias identifier: that is how the SDK's generated table lists an alias.
private func expandedEntries() throws -> [[String: Any]] {
  var expanded: [[String: Any]] = []
  for entry in try parsedLabels() {
    var canonical = entry
    canonical["alias"] = nil
    expanded.append(canonical)
    for alias in (entry["alias"] as? [String]) ?? [] {
      var copy = canonical
      copy["identifier"] = alias
      expanded.append(copy)
    }
  }
  return expanded
}

/// The upstream `labels.json`, found by walking up from this source file to a
/// checkout that contains `atproto/`. `nil` when there is none (CI, a bare clone).
private func upstreamLabelsURL() -> URL? {
  let relative = "atproto/packages/api/definitions/labels.json"
  var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  for _ in 0..<12 {
    let candidate = directory.appendingPathComponent(relative)
    if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
    directory = directory.deletingLastPathComponent()
  }
  return nil
}

@Suite("Moderation: builtin label table")
struct ModerationBuiltinTableTests {
  @Test("The embedded copy parses and has the seven upstream entries")
  func embeddedCopy() throws {
    let entries = try parsedLabels()
    #expect(entries.count == 7)
    #expect(entries.compactMap { $0["identifier"] as? String } == [
      "!hide", "!warn", "!no-unauthenticated", "porn", "sexual", "nudity", "graphic-media",
    ])
  }

  @Test("Every upstream entry, and every alias as an entry of its own, is transcribed exactly: metadata, flags, and the full behavior matrix")
  func tableMatchesLabelsJSON() throws {
    let entries = try expandedEntries()
    #expect(ModerationLabelDefinition.builtins.count == entries.count)

    for entry in entries {
      let identifier = try #require(entry["identifier"] as? String)
      let definition = try #require(ModerationLabelDefinition.builtins[identifier], "missing builtin \(identifier)")

      #expect(definition.identifier == identifier)
      #expect(definition.definedBy == nil, "\(identifier) is builtin")
      #expect(definition.locales.isEmpty)
      #expect(definition.configurable == (entry["configurable"] as? Bool), "\(identifier) configurable")
      #expect(definition.defaultSetting.rawValue == (entry["defaultSetting"] as? String), "\(identifier) defaultSetting")
      #expect(definition.severity.rawValue == (entry["severity"] as? String), "\(identifier) severity")
      #expect(definition.blurs.rawValue == (entry["blurs"] as? String), "\(identifier) blurs")

      let flags = Set((entry["flags"] as? [String]) ?? [])
      #expect(Set(definition.flags.map(\.rawValue)) == flags, "\(identifier) flags")

      let behaviors = try #require(entry["behaviors"] as? [String: [String: String]])
      for target in LabelTarget.allCases {
        let expected = behaviors[target.rawValue] ?? [:]
        let actual = try #require(definition.behaviors[target], "\(identifier) has no \(target.rawValue) behavior")
        for context in ModerationContext.allCases {
          #expect(
            actual[context]?.rawValue == expected[context.rawValue],
            "\(identifier) \(target.rawValue).\(context.rawValue)")
        }
        // No context outside the vocabulary may appear upstream.
        #expect(Set(expected.keys).isSubset(of: Set(ModerationContext.allCases.map(\.rawValue))))
      }
    }
  }

  @Test("An alias in labels.json is a builtin of its own with the canonical entry's definition and its own identifier")
  func aliases() throws {
    var aliases: Set<String> = []
    for entry in try parsedLabels() {
      let canonical = try #require(entry["identifier"] as? String)
      for alias in (entry["alias"] as? [String]) ?? [] {
        aliases.insert(alias)
        let definition = try #require(ModerationLabelDefinition.builtin(forLabelValue: alias), "missing builtin \(alias)")
        let base = try #require(ModerationLabelDefinition.builtin(forLabelValue: canonical))
        #expect(definition.identifier == alias)
        #expect(definition != base, "the identifier differs")
        #expect(
          ModerationLabelDefinition(
            identifier: canonical, configurable: definition.configurable, defaultSetting: definition.defaultSetting,
            flags: definition.flags, blurs: definition.blurs, severity: definition.severity,
            behaviors: definition.behaviors, definedBy: nil, locales: []) == base,
          "\(alias) is \(canonical) in every other respect")
        #expect(ModerationLabelDefinition.isReservedIdentifier(alias), "a labeler cannot define \(alias)")
      }
    }
    #expect(aliases == ModerationLabelDefinition.deprecatedAliasIdentifiers)
    #expect(aliases == ["gore"])
  }

  @Test("Configurable builtins are exactly the seeded preference defaults")
  func configurableDefaults() throws {
    var expected: [String: LabelPreference] = [:]
    for entry in try parsedLabels() where (entry["configurable"] as? Bool) == true {
      let identifier = try #require(entry["identifier"] as? String)
      expected[identifier] = LabelPreference(preferenceValue: try #require(entry["defaultSetting"] as? String))
    }
    #expect(ModerationPrefs.builtinDefaultLabels == expected)
  }

  @Test(
    "The embedded copy equals the upstream file",
    .enabled(if: upstreamLabelsURL() != nil, "the atproto checkout is not reachable from this source file"))
  func upstreamFileMatchesEmbeddedCopy() throws {
    let upstream = try #require(upstreamLabelsURL())
    let live = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: upstream)) as? [[String: Any]])
    let embedded = try parsedLabels()
    #expect(NSArray(array: live).isEqual(to: embedded), "labels.json changed upstream; update the table and the embedded copy")
  }
}
