import Foundation

#if os(iOS)

    struct PipelineTimeoutError: LocalizedError {
        let operation: String
        let seconds: TimeInterval

        var errorDescription: String? {
            let rounded = Int(seconds.rounded())
            return "Timed out after \(rounded)s while \(operation)."
        }
    }

    private final class TimeoutResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didResolve = false

        func tryResolve() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if didResolve { return false }
            didResolve = true
            return true
        }
    }

    final class ConversationPipelineGate: @unchecked Sendable {
        static let shared = ConversationPipelineGate()

        private let lock = NSLock()
        private var activeConversationIDs: Set<String> = []

        func begin(conversationID: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if activeConversationIDs.contains(conversationID) {
                return false
            }
            activeConversationIDs.insert(conversationID)
            return true
        }

        func end(conversationID: String) {
            lock.lock()
            defer { lock.unlock() }
            activeConversationIDs.remove(conversationID)
        }
    }

    func withTimeout<T>(
        seconds: TimeInterval,
        operationName: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = TimeoutResumeGate()

        return try await withCheckedThrowingContinuation { continuation in
            let operationTask = Task.detached(priority: .userInitiated) {
                do {
                    let value = try await operation()
                    if gate.tryResolve() {
                        continuation.resume(returning: value)
                    }
                } catch {
                    if gate.tryResolve() {
                        continuation.resume(throwing: error)
                    }
                }
            }

            Task.detached(priority: .userInitiated) {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    if gate.tryResolve() {
                        operationTask.cancel()
                        continuation.resume(
                            throwing: PipelineTimeoutError(operation: operationName, seconds: seconds)
                        )
                    }
                } catch {
                    // Ignore cancellation: if the operation completes first, the timeout is irrelevant.
                }
            }
        }
    }

#endif
