import Foundation
import OSLog

actor MLSEpochRetentionCleanupCoordinator {
  struct Conversation: Sendable, Equatable {
    let conversationID: String
    let currentEpoch: Int64
  }

  struct Status: Sendable, Equatable {
    let activeWorkerCount: Int
    let startedWorkerCount: Int
    let cancelledWorkerCount: Int
  }

  typealias Scan = @Sendable () async throws -> [Conversation]
  typealias Cleanup = @Sendable (_ conversationID: String, _ currentEpoch: Int64) async throws -> Void
  typealias Wait = @Sendable (_ interval: Duration) async throws -> Void

  static let continuousWait: Wait = { interval in
    try await Task.sleep(for: interval)
  }

  private let logger = Logger(subsystem: "blue.catbird", category: "MLSEpochRetentionCleanup")
  private var worker: Task<Void, Never>?
  private var retiringWorkers: [Task<Void, Never>] = []
  private var requestedGeneration = 0
  private var nextWorkerID = 0
  private var activeWorkerIDs: Set<Int> = []
  private var startedWorkerCount = 0
  private var cancelledWorkerCount = 0

  func restart(
    interval: Duration,
    scan: @escaping Scan,
    cleanup: @escaping Cleanup,
    wait: @escaping Wait
  ) async {
    requestedGeneration += 1
    let generation = requestedGeneration
    await retireCurrentWorker()
    guard generation == requestedGeneration else { return }
    retiringWorkers.removeAll()

    nextWorkerID += 1
    let workerID = nextWorkerID
    worker = Task { [weak self] in
      guard let self else { return }
      await self.workerStarted(workerID)
      let wasCancelled = await Self.runWorker(
        interval: interval,
        scan: scan,
        cleanup: cleanup,
        wait: wait,
        logger: self.logger
      )
      await self.workerFinished(workerID, wasCancelled: wasCancelled)
    }
  }

  func stop() async {
    requestedGeneration += 1
    let generation = requestedGeneration
    await retireCurrentWorker()
    if generation == requestedGeneration {
      retiringWorkers.removeAll()
    }
  }

  func status() -> Status {
    Status(
      activeWorkerCount: activeWorkerIDs.count,
      startedWorkerCount: startedWorkerCount,
      cancelledWorkerCount: cancelledWorkerCount
    )
  }

  private func retireCurrentWorker() async {
    if let current = worker {
      worker = nil
      current.cancel()
      retiringWorkers.append(current)
    }
    for retiringWorker in retiringWorkers {
      await retiringWorker.value
    }
  }

  private func workerStarted(_ id: Int) {
    activeWorkerIDs.insert(id)
    startedWorkerCount += 1
  }

  private func workerFinished(_ id: Int, wasCancelled: Bool) {
    activeWorkerIDs.remove(id)
    if wasCancelled { cancelledWorkerCount += 1 }
  }

  private static func runWorker(
    interval: Duration,
    scan: @escaping Scan,
    cleanup: @escaping Cleanup,
    wait: @escaping Wait,
    logger: Logger
  ) async -> Bool {
    while !Task.isCancelled {
      do {
        let conversations = try await scan()
        for conversation in conversations {
          try Task.checkCancellation()
          do {
            try await cleanup(conversation.conversationID, conversation.currentEpoch)
          } catch is CancellationError {
            return true
          } catch {
            logger.error(
              "Epoch cleanup failed for \(conversation.conversationID, privacy: .private): \(error.localizedDescription)"
            )
          }
        }
      } catch is CancellationError {
        return true
      } catch {
        logger.error("Epoch cleanup scan failed: \(error.localizedDescription)")
      }

      do {
        try await wait(interval)
      } catch {
        return Task.isCancelled || error is CancellationError
      }
    }
    return true
  }
}
