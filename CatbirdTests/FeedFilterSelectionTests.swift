import Foundation
import Testing
@testable import Catbird

@Suite("Feed filter sources and stored selections", .serialized)
@MainActor
struct FeedFilterSelectionTests {
  @Test("Effective hide combines both stored sources")
  func sources() {
    for local in [false, true] {
      for synced in [false, true] {
        #expect(FeedFilterSources(local: local, synced: synced).isHidden == (local || synced))
      }
    }
  }

  @Test("Opening keeps conflicts and unknown IDs without writing scoped settings")
  func readDoesNotReconcileLegacyValues() throws {
    let suite = "FeedFilterSelectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let legacy = ["Only Text Posts", "Only Media Posts", "future-filter"]
    defaults.set(legacy, forKey: "FeedFilterActiveFilters")
    let filters = FeedFilterSettings(accountDID: "did:plc:fixture", defaults: defaults)
    #expect(filters.contentType == .conflicting)
    #expect(filters.activeFilterIds.contains("future-filter"))
    #expect(defaults.object(forKey: AppSettingsModel.scopedKey("FeedFilterActiveFilters", accountDID: "did:plc:fixture")) == nil)
    filters.setContentType(.media)
    #expect(filters.contentType == .media)
    #expect(filters.activeFilterIds.contains("future-filter"))
    #expect(Set(try #require(defaults.stringArray(forKey: AppSettingsModel.scopedKey("FeedFilterActiveFilters", accountDID: "did:plc:fixture")))) == ["Only Media Posts", "future-filter"])
  }

  @Test("First explicit edit preserves the enabled duplicate default across reload")
  func defaultSurvivesUnrelatedEdit() throws {
    let suite = "FeedFilterSelectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let filters = FeedFilterSettings(accountDID: "did:plc:fixture", defaults: defaults)
    #expect(filters.isFilterEnabled(name: "Hide Duplicate Posts"))
    filters.setFilter(id: "Hide Link Posts", enabled: true)
    let reloaded = FeedFilterSettings(accountDID: "did:plc:fixture", defaults: defaults)
    #expect(reloaded.isFilterEnabled(name: "Hide Duplicate Posts"))
    #expect(reloaded.hideLinks)
  }
}
