import Foundation
import SwiftData

extension ModelContext {
    /// Performs a batch upsert operation for models with unique constraints.
    ///
    /// This method handles SwiftData's unique constraint limitations by:
    /// 1. Building a lookup dictionary from existing models
    /// 2. Updating existing records in place (avoiding constraint violations)
    /// 3. Inserting only genuinely new records
    ///
    /// - Parameters:
    ///   - models: Array of models to upsert
    ///   - existingModels: Array of existing models fetched from the context
    ///   - uniqueKeyPath: KeyPath to the unique identifier property
    ///   - update: Closure that updates an existing model with values from a new model
    /// - Returns: Tuple containing counts of (updated, inserted) records
    @discardableResult
    func batchUpsert<T: PersistentModel, Key: Hashable>(
        _ models: [T],
        existingModels: [T],
        uniqueKeyPath: KeyPath<T, Key>,
        update: (T, T) -> Void
    ) -> (updated: Int, inserted: Int) {
        guard !models.isEmpty else { return (0, 0) }

        // Create lookup dictionary for existing records by unique key
        var existingByKey: [Key: T] = [:]
        for existing in existingModels {
            existingByKey[existing[keyPath: uniqueKeyPath]] = existing
        }

        var updated = 0
        var inserted = 0

        for model in models {
            let key = model[keyPath: uniqueKeyPath]
            if let existing = existingByKey[key] {
                // Update existing record in place to avoid unique constraint violation
                update(existing, model)
                updated += 1
            } else {
                // Insert new record
                insert(model)
                inserted += 1
            }
        }

        return (updated, inserted)
    }

    /// Performs a single upsert operation for a model with a unique constraint.
    ///
    /// - Parameters:
    ///   - model: The model to upsert
    ///   - existingModel: Optional existing model if already fetched
    ///   - update: Closure that updates the existing model with values from the new model
    /// - Returns: The model that was either updated or inserted
    @discardableResult
    func upsert<T: PersistentModel>(
        _ model: T,
        existingModel: T?,
        update: (T, T) -> Void
    ) -> T {
        if let existing = existingModel {
            update(existing, model)
            return existing
        } else {
            insert(model)
            return model
        }
    }
}
