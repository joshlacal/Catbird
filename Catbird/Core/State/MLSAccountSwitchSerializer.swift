import Foundation
import OSLog

@available(iOS 18.0, macOS 13.0, *)
public actor MLSAccountSwitchSerializer {
  public static let shared = MLSAccountSwitchSerializer()
  private let logger = Logger(subsystem: "blue.catbird.mls", category: "AccountSwitchSerializer")
  private var activeTask: Task<Void, Error>?

  private init() {}

  public func serialize(_ block: @escaping @Sendable () async throws -> Void) async throws {
    let previous = activeTask
    let newTask = Task { [previous] in
      if let previous = previous {
        logger.info("⏳ [SWITCH-SERIALIZER] Waiting for previous account switch to complete...")
        _ = try? await previous.value
      }
      logger.info("🚀 [SWITCH-SERIALIZER] Starting serialized account switch block...")
      try await block()
    }
    activeTask = newTask

    do {
      try await newTask.value
      logger.info("✅ [SWITCH-SERIALIZER] Account switch block completed successfully")
    } catch {
      logger.error("❌ [SWITCH-SERIALIZER] Account switch block failed: \(error.localizedDescription)")
      throw error
    }
  }
}
