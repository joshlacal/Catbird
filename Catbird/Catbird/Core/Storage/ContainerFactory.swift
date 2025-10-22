import Foundation
import SwiftData

@available(iOS 26.0, macOS 26.0, *)
enum ContainerFactory {
  static func make(
    cloudContainerIdentifier: String? = nil,
    includeLocalOnlyGroup: Bool = true
  ) throws -> ModelContainer {
    let cloudConfig: ModelConfiguration
    if let id = cloudContainerIdentifier {
      cloudConfig = ModelConfiguration(
        _ : "Cloud",
        schema: Schema([AppSettings.self, Draft.self, DraftAttachment.self]),
        url: nil,
        allowsSave: true,
        cloudKitDatabase: .private(id)
      )
    } else {
      cloudConfig = ModelConfiguration(
        for: [AppSettings.self, Draft.self, DraftAttachment.self],
        isStoredInMemoryOnly: false
      )
    }

    let container = try ModelContainer(
      for: AppSettings.self, Draft.self, DraftAttachment.self,
      configurations: [cloudConfig]
    )
    return container
  }
}
