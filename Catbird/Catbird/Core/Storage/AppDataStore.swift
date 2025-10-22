import Foundation
import OSLog
import SwiftData

@available(iOS 26.0, macOS 26.0, *)
@ModelActor
actor AppDataStore {
  // MARK: - Properties
  let modelContainer: ModelContainer
  private let log = Logger(subsystem: "com.catbird.app", category: "AppDataStore")

  // MARK: - Init
  nonisolated init(container: ModelContainer) {
    self.modelContainer = container
    // Use a non-main context for serialized storage work
    self.modelExecutor = DefaultSerialModelExecutor(
      modelContext: ModelContext(container)
    )
  }

  // MARK: - Settings
  func loadSettings() throws -> AppSettings {
    if let s = try modelContext.fetch(FetchDescriptor<AppSettings>()).first {
      return s
    }
    let s = AppSettings()
    modelContext.insert(s)
    try modelContext.save()
    log.debug("Created default AppSettings")
    return s
  }

  func updateSettings(_ apply: (inout AppSettings) -> Void) throws {
    var s = try loadSettings()
    apply(&s)
    s.updatedAt = .now
    try modelContext.save()
    log.debug("Saved AppSettings")
  }

  // MARK: - Drafts
  func drafts() throws -> [Draft] {
    try modelContext.fetch(FetchDescriptor<Draft>(sortBy: [.init(\._updatedAt, order: .reverse)]))
  }

  func upsertDraft(_ draft: Draft) throws {
    modelContext.insert(draft)
    draft.updatedAt = .now
    try modelContext.save()
    log.debug("Upserted Draft \(draft.id.uuidString)")
  }

  func deleteDraft(_ id: UUID) throws {
    if let d = try modelContext.fetch(FetchDescriptor<Draft>(predicate: #Predicate { $0.id == id })).first {
      modelContext.delete(d)
      try modelContext.save()
      log.debug("Deleted Draft \(id.uuidString)")
    }
  }
}
