import Foundation
import SwiftData
import OSLog

/// Central SwiftData model actor for serialized writes (drafts/settings)
/// Uses its own ModelContext via DefaultSerialModelExecutor to avoid main-actor contention.
@available(iOS 26.0, macOS 26.0, *)
@ModelActor
actor AppModelStore {
  private let log = Logger(subsystem: "blue.catbird", category: "AppModelStore")
  let modelContainer: ModelContainer

  nonisolated init(container: ModelContainer) {
    self.modelContainer = container
    self.modelExecutor = DefaultSerialModelExecutor(
      modelContext: ModelContext(container)
    )
  }

  // MARK: - Settings (AppSettingsModel)

  func loadAppSettings() throws -> AppSettingsModel {
    if let s = try modelContext.fetch(FetchDescriptor<AppSettingsModel>(predicate: #Predicate { $0.id == "app_settings" })).first {
      return s
    }
    let s = AppSettingsModel()
    s.migrateFromUserDefaults()
    modelContext.insert(s)
    try modelContext.save()
    log.debug("Created default AppSettingsModel")
    return s
  }

  func updateAppSettings(_ apply: (inout AppSettingsModel) -> Void) throws {
    var s = try loadAppSettings()
    apply(&s)
    try modelContext.save()
  }

  // MARK: - Drafts (DraftPost)

  func saveDraft(_ draft: PostComposerDraft, accountDID: String) throws -> UUID {
    let draftPost = try DraftPost.create(from: draft, accountDID: accountDID)
    modelContext.insert(draftPost)
    try modelContext.save()
    return draftPost.id
  }

  func fetchDrafts(for accountDID: String) throws -> [DraftPost] {
    let predicate = #Predicate<DraftPost> { $0.accountDID == accountDID }
    var descriptor = FetchDescriptor(predicate: predicate)
    descriptor.sortBy = [SortDescriptor(\.modifiedDate, order: .reverse)]
    return try modelContext.fetch(descriptor)
  }

  func deleteDraft(id: UUID) throws {
    let predicate = #Predicate<DraftPost> { $0.id == id }
    let descriptor = FetchDescriptor(predicate: predicate)
    if let d = try modelContext.fetch(descriptor).first {
      modelContext.delete(d)
      try modelContext.save()
    }
  }
}
