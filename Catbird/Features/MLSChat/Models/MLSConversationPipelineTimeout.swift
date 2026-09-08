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

        struct BackoffState: Equatable, Sendable {
            var failureCount: Int
            var nextAllowedAttempt: Date
        }

        private let lock = NSLock()
        private var inFlightTasks: [String: Task<Bool, Never>] = [:]
        private var activeConversationIDs: Set<String> = []
        private var backoffs: [String: BackoffState] = [:]
        private var joinedCallers: [String: Int] = [:]
        let timeProvider: @Sendable () -> Date
        let initialBackoff: TimeInterval
        let maxBackoff: TimeInterval
        let backoffMultiplier: Double

        init(
            timeProvider: @escaping @Sendable () -> Date = { Date() },
            initialBackoff: TimeInterval = 1.0,
            maxBackoff: TimeInterval = 30.0,
            backoffMultiplier: Double = 2.0
        ) {
            self.timeProvider = timeProvider
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
            self.backoffMultiplier = backoffMultiplier
        }

        /// Runs the pipeline operation for the given conversation with in-flight join
        /// and bounded failure backoff.
        /// - Parameters:
        ///   - conversationID: Stable conversation identifier.
        ///   - isUserInitiated: True for explicit user actions (e.g. tapping Retry) which bypass backoff.
        ///   - operation: The pipeline execution returning true on success, false on failure.
        /// - Returns: true if the pipeline succeeded, false if it failed or was throttled.
        func run(
            conversationID: String,
            isUserInitiated: Bool = false,
            operation: @escaping @Sendable () async -> Bool
        ) async -> Bool {
            let task: Task<Bool, Never>

            lock.lock()
            // 1. In-flight join: collapse concurrent callers to the single active run.
            if let existing = inFlightTasks[conversationID] {
                joinedCallers[conversationID, default: 0] += 1
                lock.unlock()
                return await existing.value
            }

            // 2. Backoff cooldown check for automated/ambient triggers.
            let now = timeProvider()
            if !isUserInitiated, let state = backoffs[conversationID] {
                if now < state.nextAllowedAttempt {
                    lock.unlock()
                    return false
                }
            }

            if isUserInitiated {
                // User-initiated retry clears any active cooldown.
                backoffs.removeValue(forKey: conversationID)
            }

            activeConversationIDs.insert(conversationID)
            // 3. Launch single in-flight task
            task = Task<Bool, Never> { [weak self, timeProvider, initialBackoff, maxBackoff, backoffMultiplier] in
                let success = await operation()
                guard let self else { return success }

                self.lock.lock()
                defer { self.lock.unlock() }

                self.inFlightTasks.removeValue(forKey: conversationID)
                self.activeConversationIDs.remove(conversationID)

                if success {
                    self.backoffs.removeValue(forKey: conversationID)
                } else {
                    let currentCount = self.backoffs[conversationID]?.failureCount ?? 0
                    let newCount = currentCount + 1
                    let multiplier = pow(backoffMultiplier, Double(newCount - 1))
                    let delay = min(maxBackoff, initialBackoff * multiplier)
                    let next = timeProvider().addingTimeInterval(delay)
                    self.backoffs[conversationID] = BackoffState(
                        failureCount: newCount,
                        nextAllowedAttempt: next
                    )
                }
                return success
            }

            inFlightTasks[conversationID] = task
            lock.unlock()

            return await task.value
        }

        func begin(conversationID: String, isUserInitiated: Bool = false) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if activeConversationIDs.contains(conversationID) || inFlightTasks[conversationID] != nil {
                return false
            }
            let now = timeProvider()
            if !isUserInitiated, let state = backoffs[conversationID] {
                if now < state.nextAllowedAttempt {
                    return false
                }
            }
            if isUserInitiated {
                backoffs.removeValue(forKey: conversationID)
            }
            activeConversationIDs.insert(conversationID)
            return true
        }

        func end(conversationID: String, success: Bool = false) {
            lock.lock()
            defer { lock.unlock() }
            activeConversationIDs.remove(conversationID)
            inFlightTasks.removeValue(forKey: conversationID)
            if success {
                backoffs.removeValue(forKey: conversationID)
            } else {
                let currentCount = backoffs[conversationID]?.failureCount ?? 0
                let newCount = currentCount + 1
                let multiplier = pow(backoffMultiplier, Double(newCount - 1))
                let delay = min(maxBackoff, initialBackoff * multiplier)
                let next = timeProvider().addingTimeInterval(delay)
                backoffs[conversationID] = BackoffState(
                    failureCount: newCount,
                    nextAllowedAttempt: next
                )
            }
        }

        func resetBackoff(for conversationID: String) {
            lock.lock()
            defer { lock.unlock() }
            backoffs.removeValue(forKey: conversationID)
        }

        func isInFlight(conversationID: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return activeConversationIDs.contains(conversationID) || inFlightTasks[conversationID] != nil
        }

        func failureCount(for conversationID: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return backoffs[conversationID]?.failureCount ?? 0
        }

        func nextAllowedAttempt(for conversationID: String) -> Date? {
            lock.lock()
            defer { lock.unlock() }
            return backoffs[conversationID]?.nextAllowedAttempt
        }

        func resetAll() {
            lock.lock()
            defer { lock.unlock() }
            inFlightTasks.removeAll()
            activeConversationIDs.removeAll()
            backoffs.removeAll()
            joinedCallers.removeAll()
        }

        func joinedCallersCount(for conversationID: String) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return joinedCallers[conversationID] ?? 0
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
