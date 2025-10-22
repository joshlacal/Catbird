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
      // Explicitly enable CloudKit only when identifier is provided
      cloudConfig = ModelConfiguration(
        _ : "Cloud",
        schema: Schema([AppSettings.self, Draft.self, DraftAttachment.self]),
        url: nil,
        allowsSave: true,
        cloudKitDatabase: .private(id)
      )
    } else {
      // Opt out of automatic CloudKit detection by default to avoid schema constraints
      cloudConfig = ModelConfiguration(cloudKitDatabase: .none)
    }

    let container = try ModelContainer(
      for: AppSettings.self, Draft.self, DraftAttachment.self,
      configurations: [cloudConfig]
    )
    return container
  }
}
