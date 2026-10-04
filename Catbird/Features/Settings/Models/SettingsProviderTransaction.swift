import Foundation

/// Explicit account switching must wait while the SDK applies and persists provider mappings.
@MainActor enum SettingsAccountOperationGate {
    private static var activeToken: UUID?
    private(set) static var activeAccountDID: String?
    static func begin(for accountDID: String) -> UUID? {
        guard activeToken == nil else { return nil }
        let token = UUID()
        activeToken = token
        activeAccountDID = accountDID
        return token
    }
    static func end(token: UUID) {
        guard activeToken == token else { return }
        activeToken = nil
        activeAccountDID = nil
    }
}

struct SettingsProviderServiceDIDs: Equatable, Sendable {
    let appView: String
    let chat: String
}

@MainActor enum SettingsProviderTransaction {
    enum Failure: LocalizedError {
        case operationInProgress
        var errorDescription: String? { "Another account operation is in progress. Try again after it finishes." }
    }
    /// Restores the captured runtime mapping after a failed persistence attempt.
    /// A thrown SDK save may have written the account record before its account-list update failed.
    /// Runtime restoration does not prove durable rollback.
    /// Account expiry and logout remain SDK boundaries because that API has no explicit account argument.
    static func apply(
        accountDID: String,
        requested: SettingsProviderServiceDIDs,
        original: SettingsProviderServiceDIDs,
        isCurrent: @MainActor () -> Bool,
        persist: @MainActor (SettingsProviderServiceDIDs) async throws -> Void,
        restoreRuntime: @MainActor (SettingsProviderServiceDIDs) async -> Void
    ) async throws {
        guard isCurrent() else { throw CancellationError() }
        guard let token = SettingsAccountOperationGate.begin(for: accountDID) else { throw Failure.operationInProgress }
        defer { SettingsAccountOperationGate.end(token: token) }
        do {
            try await persist(requested)
            guard isCurrent() else { throw CancellationError() }
        } catch {
            if isCurrent() { await restoreRuntime(original) }
            throw error
        }
    }
}
