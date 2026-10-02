import Foundation
import Observation

/// Owns one appeal attempt. A canceled attempt cannot publish into its replacement.
@MainActor
@Observable
final class LabelAppealSubmission {
  private(set) var isSubmitting = false
  private(set) var errorMessage: String?
  private(set) var successCount = 0
  private var attemptID: UUID?
  private var task: Task<Void, Never>?

  @discardableResult
  func submit(_ operation: @escaping @MainActor () async throws -> Bool) -> Task<Void, Never>? {
    guard !isSubmitting else { return nil }
    let id = UUID()
    attemptID = id
    isSubmitting = true
    errorMessage = nil
    let attempt = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.attemptID == id {
          self.isSubmitting = false
          self.task = nil
          self.attemptID = nil
        }
      }
      do {
        let succeeded = try await operation()
        guard !Task.isCancelled, self.attemptID == id else { return }
        if succeeded {
          self.successCount += 1
        } else {
          self.errorMessage = "Failed to submit your appeal. Your reason is preserved; please try again."
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, self.attemptID == id else { return }
        self.errorMessage = error.localizedDescription
      }
    }
    task = attempt
    return attempt
  }

  func reset() {
    cancel()
    errorMessage = nil
  }

  func cancel() {
    attemptID = nil
    task?.cancel()
    task = nil
    isSubmitting = false
  }
}
