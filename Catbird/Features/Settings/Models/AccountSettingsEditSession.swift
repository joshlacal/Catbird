import Foundation
import Observation

/// A remote editor owns a confirmed snapshot and the account that loaded it.
@MainActor
@Observable
final class AccountSettingsEditSession<Value> {
  enum State: Equatable, Sendable {
    case unavailable
    case loading
    case ready
    case saving
    case loadFailed
    case saveFailed
  }

  let accountDID: String
  private(set) var state: State = .unavailable
  private(set) var confirmedValue: Value?
  private(set) var proposedValue: Value?
  private(set) var errorMessage: String?

  @ObservationIgnored private let loadValue: @MainActor () async throws -> Value
  @ObservationIgnored private let saveValue: @MainActor (Value) async throws -> Value
  @ObservationIgnored private let isCurrentAccount: @MainActor () -> Bool
  @ObservationIgnored private let allowEditingAfterSaveFailure: Bool
  @ObservationIgnored private var generation: UInt64 = 0
  @ObservationIgnored private var failedValue: Value?
  @ObservationIgnored private var saveTask: Task<Void, Never>?

  init(
    accountDID: String,
    allowEditingAfterSaveFailure: Bool = true,
    isCurrentAccount: @escaping @MainActor () -> Bool,
    load: @escaping @MainActor () async throws -> Value,
    save: @escaping @MainActor (Value) async throws -> Value
  ) {
    self.accountDID = accountDID
    self.isCurrentAccount = isCurrentAccount
    self.allowEditingAfterSaveFailure = allowEditingAfterSaveFailure
    self.loadValue = load
    self.saveValue = save
  }

  var canEdit: Bool {
    isCurrentAccount() && (state == .ready || (state == .saveFailed && allowEditingAfterSaveFailure))
  }

  var displayedValue: Value? {
    state == .saving ? proposedValue : confirmedValue
  }

  func load() async {
    guard isCurrentAccount(), !Task.isCancelled else { return }
    generation &+= 1
    let request = generation
    saveTask?.cancel()
    saveTask = nil
    state = .loading
    errorMessage = nil
    failedValue = nil
    proposedValue = nil
    do {
      let value = try await loadValue()
      guard accepts(request) else { return }
      confirmedValue = value
      state = .ready
    } catch {
      guard accepts(request) else { return }
      errorMessage = UserFacingError.message(for: error, action: "load this setting")
      state = .loadFailed
    }
  }

  /// Admission is synchronous so two taps cannot start overlapping writes.
  @discardableResult
  func submit(_ value: Value) -> Task<Void, Never>? {
    submit(value, isRetry: false)
  }

  private func submit(_ value: Value, isRetry: Bool) -> Task<Void, Never>? {
    guard isCurrentAccount(),
      state == .ready || (state == .saveFailed && (allowEditingAfterSaveFailure || isRetry))
    else { return nil }
    generation &+= 1
    let request = generation
    proposedValue = value
    failedValue = nil
    errorMessage = nil
    state = .saving
    let task = Task { @MainActor [weak self] in
      guard let self, self.accepts(request) else { return }
      defer {
        if self.generation == request { self.saveTask = nil }
      }
      do {
        let accepted = try await self.saveValue(value)
        guard self.accepts(request) else { return }
        self.confirmedValue = accepted
        self.proposedValue = nil
        self.state = .ready
      } catch {
        guard self.accepts(request) else { return }
        self.failedValue = value
        self.proposedValue = nil
        self.errorMessage = UserFacingError.message(for: error, action: "save this change")
        self.state = .saveFailed
      }
    }
    saveTask = task
    return task
  }

  @discardableResult
  func retrySave() -> Task<Void, Never>? {
    guard state == .saveFailed, let failedValue else { return nil }
    return submit(failedValue, isRetry: true)
  }

  func invalidate() {
    generation &+= 1
    saveTask?.cancel()
    saveTask = nil
    proposedValue = nil
    failedValue = nil
    state = .unavailable
  }

  private func accepts(_ request: UInt64) -> Bool {
    guard generation == request else { return false }
    guard isCurrentAccount(), !Task.isCancelled else {
      proposedValue = nil
      failedValue = nil
      state = .unavailable
      return false
    }
    return true
  }
}
